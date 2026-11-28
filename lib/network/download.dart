import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/archive_security.dart';

import 'file_downloader.dart';
import 'download_page.dart';

abstract class DownloadTask with ChangeNotifier {
  Future<void>? _activeRun;
  bool _resumeRequested = false;

  /// Includes final library/queue persistence, even after the row disappears.
  Future<void> get settled => _activeRun ?? Future<void>.value();

  void _runSerialized(
    Future<void> Function() action,
    void Function(String) onError,
  ) {
    if (_activeRun != null) {
      if (isPaused) _resumeRequested = true;
      return;
    }
    _resumeRequested = false;
    _activeRun = Future<void>.sync(action)
        .catchError((Object error, StackTrace stack) {
          onError('Error: $error');
          Log.error('Download', error, stack);
        })
        .whenComplete(() {
          _activeRun = null;
          if (_resumeRequested) resume();
        });
  }

  BackgroundTask? _backgroundTask;

  String get backgroundTaskKey => 'download:${comicType.value}:$id';

  int get completedUnits => 0;
  int? get totalUnits => null;

  /// Queue restoration and direct resume calls share the same task record.
  void trackBackgroundTask({bool queued = false}) {
    if (_backgroundTask?.isRunning != true) {
      _backgroundTask = BackgroundTasks.instance.start(
        backgroundTaskKey,
        'Download: $title',
        cancellable: true,
      )..onCancel = cancel;
    }
    _updateBackgroundTask(queued: queued);
  }

  void _updateBackgroundTask({bool queued = false}) {
    final task = _backgroundTask;
    if (task == null || !task.isRunning) return;
    task.update(
      completed: completedUnits,
      total: totalUnits,
      message: task.cancelRequested
          ? 'Cancelling...'
          : queued
          ? 'Queued'
          : message,
    );
    if (isError && !task.cancelRequested) {
      task.onCancel = null;
      task.fail(message);
    }
  }

  void completeBackgroundTask() {
    _updateBackgroundTask();
    _backgroundTask?.onCancel = null;
    _backgroundTask?.finish(message: 'Download completed');
  }

  void failBackgroundTask(Object error) {
    _backgroundTask?.onCancel = null;
    _backgroundTask?.fail(error);
  }

  void _requestBackgroundCancellation() {
    _resumeRequested = false;
    final task = _backgroundTask;
    if (task == null || !task.isRunning) return;
    task.cancelRequested = true;
    task.update(message: 'Cancelling...');
  }

  void _finishBackgroundCancellation() {
    _backgroundTask?.onCancel = null;
    _backgroundTask?.finish(message: 'Cancelled');
  }

  @override
  void notifyListeners() {
    _updateBackgroundTask();
    super.notifyListeners();
  }

  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  static String? restoreManagedPath(Object? value) {
    if (value == null) return null;
    if (value is! String ||
        value.isEmpty ||
        value.length > 4096 ||
        !LocalManager().isManagedPath(value)) {
      throw const FormatException(
        'Download task path is outside local storage',
      );
    }
    return value;
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  // 1x1 transparent PNG used to keep page order when an image is skipped.
  static const _skippedImagePlaceholderBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=';

  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  bool _createdDownloadDirectory = false;
  String? _ownerToken;
  bool _committing = false;

  Future<bool> _matchesDirectoryOwner(Directory dir) async {
    final file = dir.joinFile(_downloadInfoFileName);
    if (_ownerToken == null || !await file.exists()) return false;
    final info = jsonDecode(utf8.decode(await file.readAsBytes()));
    return info is Map &&
        info['owner'] == _ownerToken &&
        info['id'] == id &&
        info['type'] == comicType.value;
  }

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  final _createdFiles = <String>{};
  bool _cancelled = false;

  Future<void> _recordNewFile(File file) async {
    if (!_createdDownloadDirectory && !await file.exists()) {
      if (_createdFiles.add(file.path)) {
        await LocalManager().saveCurrentDownloadingTasks();
      }
    }
  }

  @override
  void cancel() {
    if (_cancelled || _committing) return;
    _cancelled = true;
    _requestBackgroundCancellation();
    _isRunning = false;
    stopRecorder();
    unawaited(_cancelAndClean());
  }

  Future<void> _cancelAndClean() async {
    try {
      await _cancelPendingDownloads();
      await settled;
      final root = path;
      final manager = LocalManager();
      if (root == null || !manager.isManagedPath(root)) return;
      final dir = Directory(root);
      if (_createdDownloadDirectory && manager.find(id, comicType) == null) {
        if (await _matchesDirectoryOwner(dir)) {
          await dir.delete(recursive: true);
        }
      } else {
        for (final name in _createdFiles) {
          final file = File(name);
          if (!manager.isManagedPath(name) ||
              !(file.parent.path == root || file.parent.parent.path == root)) {
            continue;
          }
          if (await file.exists()) await file.delete();
        }
        // Leave an old, unowned partial download marked so refresh skips it.
        if (manager.find(id, comicType) != null) await _deleteDownloadInfo();
      }
    } catch (e, s) {
      _backgroundTask?.addError('Download cleanup: $e');
      Log.error('Download', e, s);
    } finally {
      LocalManager().removeTask(this);
      _finishBackgroundCancellation();
    }
  }

  Future<void> _cancelPendingDownloads() async {
    var pendingTasks = tasks.values.toList();
    for (var i = 0; i < pendingTasks.length; i++) {
      if (!pendingTasks[i].isComplete) {
        pendingTasks[i].cancel();
        await pendingTasks[i].wait();
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    _resumeRequested = false;
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused";
    _currentSpeed = 0;
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
      }
    }
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  @override
  int get completedUnits => _downloadedCount;
  @override
  int? get totalUnits => _totalCount > 0 ? _totalCount : null;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  int _skippedImageCount = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  static const _downloadInfoFileName = ".venera_download.json";

  Future<void> _writeDownloadInfo() async {
    if (path == null || comic == null) {
      return;
    }
    try {
      var file = Directory(path!).joinFile(_downloadInfoFileName);
      await file.writeAsBytes(
        utf8.encode(
          jsonEncode({
            "id": comicId,
            if (_ownerToken != null) "owner": _ownerToken,
            "type": comicType.value,
            "source": source.key,
            "title": comic!.title,
          }),
        ),
      );
    } catch (e, s) {
      Log.error("Download", "Failed to write download info: $e", s);
      rethrow;
    }
  }

  Future<void> _deleteDownloadInfo() async {
    if (path == null) {
      return;
    }
    await Directory(path!).joinFile(_downloadInfoFileName).deleteIgnoreError();
  }

  Directory _chapterDirectory(String chapterId) {
    return Directory(
      FilePath.join(path!, LocalManager.getChapterDirectoryName(chapterId)),
    );
  }

  Directory _currentSaveDirectory() {
    if (comic!.chapters != null) {
      return _chapterDirectory(_images!.keys.elementAt(_chapter));
    }
    return Directory(path!);
  }

  Iterable<String> _requestedChapterIds() sync* {
    var comicChapters = comic?.chapters;
    if (comicChapters == null) {
      return;
    }
    var selectedChapters = chapters?.toSet();
    for (var chapterId in comicChapters.ids) {
      if (selectedChapters == null || selectedChapters.contains(chapterId)) {
        yield chapterId;
      }
    }
  }

  List<String> _chapterIdsNeedingImageList() {
    if (comic?.chapters == null) {
      return const [];
    }
    var images = _images;
    return _requestedChapterIds()
        .where((id) => images?[id]?.isNotEmpty != true)
        .toList();
  }

  void _refreshTotalCount() {
    _totalCount =
        _images?.values.fold<int>(
          0,
          (total, images) => total + images.length,
        ) ??
        0;
  }

  Future<Map<String, Set<int>>> _scanChapters() async {
    final result = <String, Set<int>>{};
    for (final entry in _images!.entries) {
      if (!_isRunning) break;
      final dir = comic!.chapters == null
          ? Directory(path!)
          : _chapterDirectory(entry.key);
      result[entry.key] = await _downloadedPageIndexes(dir, entry.value.length);
    }
    return result;
  }

  String _formatDownloadProgressMessage() {
    var message = "$_downloadedCount/$_totalCount";
    if (_skippedImageCount > 0) {
      message += " ($_skippedImageCount skipped)";
    }
    return message;
  }

  Future<void> _writeSkippedImagePlaceholder(
    Directory saveTo,
    int index,
    Object error,
  ) async {
    if (!saveTo.existsSync()) {
      saveTo.createSync(recursive: true);
    }
    var file = saveTo.joinFile("$index.png");
    await _recordNewFile(file);
    await file.writeAsBytes(base64Decode(_skippedImagePlaceholderBase64));
    var errorFile = saveTo.joinFile(".$index.error.txt");
    await _recordNewFile(errorFile);
    await errorFile.writeAsBytes(utf8.encode(error.toString()));
    _skippedImageCount++;
  }

  Future<Set<int>> _downloadedPageIndexes(
    Directory directory,
    int count,
  ) async {
    final indexes = <int>{};
    final failed = <int>{};
    void inspect(String name, int size) {
      final marker = RegExp(r'^\.(\d+)\.error\.txt$').firstMatch(name);
      if (marker != null) {
        final index = int.tryParse(marker[1]!);
        if (index != null) failed.add(index);
        return;
      }
      final dot = name.lastIndexOf('.');
      final index = int.tryParse(dot < 0 ? name : name.substring(0, dot));
      if (index != null && index >= 0 && index < count && size > 0) {
        indexes.add(index);
      }
    }

    if (directory.path.startsWith('android://')) {
      final sizes = await const MethodChannel(
        'flutter_saf/metadata',
      ).invokeMapMethod<String, int>('fileSizes', directory.path);
      if (sizes == null) throw StateError('Missing SAF directory listing');
      sizes.forEach(inspect);
    } else if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) {
          inspect(entity.name, await File(entity.path).length());
        }
      }
    }
    return indexes..removeAll(failed);
  }

  List<String> _verifiedChapters = [];

  String? _downloadCompletionError(Map<String, Set<int>> pagesOnDisk) {
    var images = _images;
    if (images == null || images.isEmpty) {
      return "Error: No image list found";
    }
    if (_totalCount == 0) {
      return "Error: Image list is empty";
    }
    if (comic?.chapters == null) {
      var pages = images[''];
      if (pages == null || pages.isEmpty) {
        return "Error: Image list is empty";
      }
      if (pagesOnDisk['']?.length != pages.length) {
        return "Error: Downloaded images are incomplete";
      }
      return null;
    }
    var requestedChapters = _requestedChapterIds().toList();
    if (requestedChapters.isEmpty) {
      return "Error: No chapters to download";
    }
    if (_chapterIdsNeedingImageList().isNotEmpty) {
      return "Error: Image list is incomplete";
    }
    _verifiedChapters = requestedChapters
        .where((id) => pagesOnDisk[id]?.length == images[id]!.length)
        .toList();
    if (_verifiedChapters.length != requestedChapters.length) {
      return "Error: Downloaded chapters are incomplete";
    }
    return null;
  }

  int get _maxConcurrentTasks {
    final value = appdata.settings["downloadThreads"];
    if (value is! num || !value.isFinite) {
      return 1;
    }
    return value.toInt().clamp(1, 32);
  }

  void _scheduleTasks(Set<int> downloadedPages, Directory saveTo) {
    if (!_isRunning || _chapter >= _images!.length) {
      return;
    }
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloadedPages.contains(i)) {
        continue;
      }
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      final scheduledChapter = _chapter;
      task
          .wait()
          .then((task) {
            if (_isRunning &&
                task.isComplete &&
                scheduledChapter == _chapter &&
                identical(tasks[i], task)) {
              _scheduleTasks(downloadedPages, saveTo);
            }
          })
          .catchError((Object error, StackTrace stack) {
            _setError('Error: $error');
            Log.error('Download', error, stack);
          });
      downloading++;
    }
  }

  @override
  void resume() {
    if (!_cancelled) _runSerialized(_resume, _setError);
  }

  Future<void> _resume() async {
    if (_isRunning) return;
    _isError = false;
    _message = "Resuming...";
    _isRunning = true;
    trackBackgroundTask();
    await _cancelPendingDownloads();
    if (!_isRunning) return;
    tasks.clear();
    // Serialized cursors may already be past failed pages (or the last
    // chapter). Re-scan disk and reuse successful pages on every resume.
    _chapter = 0;
    _index = 0;
    _skippedImageCount = 0;
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      }, shouldContinue: () => _isRunning);
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    final restoringOwnedDirectory = path != null && _createdDownloadDirectory;
    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        final existed = await dir.exists();
        if (!existed) {
          await dir.create();
        }
        path = dir.path;
        _createdDownloadDirectory = !existed;
        if (!existed) {
          _ownerToken = DateTime.now().microsecondsSinceEpoch.toString();
        }
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    if (path == null || !LocalManager().isManagedPath(path!)) {
      _setError("Error: Download path is outside local storage");
      return;
    }

    if (restoringOwnedDirectory &&
        !await _matchesDirectoryOwner(Directory(path!))) {
      throw StateError('Download folder has changed since the task was saved');
    }
    await _writeDownloadInfo();
    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
        )) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        if (!_isRunning) throw StateError("Download stopped");
        if (!await file.exists()) {
          await _recordNewFile(file);
          await file.writeAsBytes(data);
        }
        return "file://${file.path}";
      }, shouldContinue: () => _isRunning);
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    var shouldFetchImages =
        _images == null ||
        (comic!.chapters == null
            ? _images!['']?.isNotEmpty != true
            : _chapterIdsNeedingImageList().isNotEmpty);
    if (shouldFetchImages) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        }, shouldContinue: () => _isRunning);
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _refreshTotalCount();
        }
      } else {
        _images ??= {};
        _refreshTotalCount();
        int cpCount = 0;
        var chaptersNeedingImageList = _chapterIdsNeedingImageList();
        int totalCpCount = chaptersNeedingImageList.length;
        for (var i in chaptersNeedingImageList) {
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          var res = await _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, i);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          }, shouldContinue: () => _isRunning);
          if (!_isRunning) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images![i] = res.data;
            _refreshTotalCount();
          }
          cpCount++;
        }
      }
      _refreshTotalCount();
      _message = _formatDownloadProgressMessage();
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    } else {
      _refreshTotalCount();
    }
    final scanned = await _scanChapters();
    _downloadedCount = scanned.values.fold(
      0,
      (total, pages) => total + pages.length,
    );
    _message = _formatDownloadProgressMessage();
    notifyListeners();

    if (!_isRunning) return;

    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      var saveTo = _currentSaveDirectory();
      if (!saveTo.existsSync()) {
        saveTo.createSync(recursive: true);
      }
      var downloadedPages = scanned[_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        if (downloadedPages.contains(_index)) {
          _index++;
          _message = _formatDownloadProgressMessage();
          LocalManager().scheduleCurrentDownloadingTasksSave();
          continue;
        }
        _scheduleTasks(downloadedPages, saveTo);
        var task = tasks[_index]!;
        await task.wait();
        if (isPaused) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        if (task.skippedError != null) {
          _backgroundTask?.addError(
            'Page ${task.index + 1}: ${task.skippedError}',
          );
          Log.error("Download", "Skipped image: ${task.skippedError}");
        }
        _index++;
        _downloadedCount++;
        downloadedPages.add(task.index);
        _message = _formatDownloadProgressMessage();
        _updateBackgroundTask();
        LocalManager().scheduleCurrentDownloadingTasksSave();
      }
      _index = 0;
      _chapter++;
    }

    final verified = await _scanChapters();
    if (!_isRunning) return;
    var completionError = _downloadCompletionError(verified);
    if (completionError != null) {
      _setError(completionError);
      return;
    }

    _committing = true;
    try {
      await LocalManager().completeTask(this);
      await _deleteDownloadInfo();
    } finally {
      _committing = false;
    }
    _isRunning = false;
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "createdDirectory": _createdDownloadDirectory,
      "owner": _ownerToken,
      "createdFiles": _createdFiles.toList(),
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "skippedImageCount": _skippedImageCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    final source = ComicSource.find(json["source"]);
    if (source == null) return null;
    return ImagesDownloadTask(
        source: source,
        comicId: json["comicId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        chapters: ListOrNull.from(json["chapters"]),
      )
      ..path = DownloadTask.restoreManagedPath(json["path"])
      .._ownerToken = json["owner"] as String?
      .._createdDownloadDirectory =
          json["createdDirectory"] == true && json["owner"] != null
      .._createdFiles.addAll(
        List<String>.from(json["createdFiles"] ?? const []),
      )
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._skippedImageCount = json["skippedImageCount"] ?? 0
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: _verifiedChapters,
      createdAt: DateTime.now(),
      language: comic?.language,
      pageCount: _storedPageCount(),
    );
  }

  /// Pages actually present on disk, falling back to the planned total when
  /// the page manifest is no longer available.
  int? _storedPageCount() {
    final stored = _countDownloadedPagesOnDisk();
    if (stored > 0) return stored;
    return _totalCount > 0 ? _totalCount : null;
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 6,
  bool Function()? shouldContinue,
}) async {
  for (var i = 0; i < retry; i++) {
    if (shouldContinue != null && !shouldContinue()) {
      return const Res.error("Canceled");
    }
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: (i + 1).clamp(1, 30)));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  String? skippedError;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
    var pendingWrite = _pendingWrite;
    if (pendingWrite == null) {
      _completeWaiters();
    } else {
      unawaited(pendingWrite.catchError((_) {}).whenComplete(_completeWaiters));
    }
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 6;

  Future<void>? _pendingWrite;

  void _completeWaiters() {
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
        cacheResult: false,
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          var pendingWrite = task
              ._recordNewFile(file)
              .then((_) => writeDownloadedPage(file, index, p.imageBytes!));
          _pendingWrite = pendingWrite;
          try {
            await pendingWrite;
          } finally {
            _pendingWrite = null;
          }
          if (isCancelled) {
            _completeWaiters();
            return;
          }
          isComplete = true;
          _completeWaiters();
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        _completeWaiters();
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        unawaited(
          Future.delayed(Duration(seconds: _retryDelaySeconds())).then((_) {
            if (!isCancelled) {
              start();
            }
          }),
        );
        return;
      }
      try {
        _pendingWrite = task._writeSkippedImagePlaceholder(saveTo, index, e);
        await _pendingWrite;
        _pendingWrite = null;
        skippedError = e.toString();
        isComplete = true;
      } catch (writeError, stackTrace) {
        Log.error("Download", writeError.toString(), stackTrace);
        error = "$e\nFailed to write skipped image placeholder: $writeError";
      }
      _completeWaiters();
    }
  }

  int _retryDelaySeconds() {
    var usedRetries = 6 - retry;
    return usedRetries.clamp(1, 30);
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete || error != null || (isCancelled && _pendingWrite == null)) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;
  Future<void>? _extracting;

  bool _createdDownloadDirectory = false;

  String get _taskKey {
    var hash = 0x811c9dc5;
    for (final codeUnit in '$id:${comicType.value}:$archiveUrl'.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  File get _archiveFile =>
      File(FilePath.join(App.dataPath, 'archive_downloading_$_taskKey.zip'));

  File get _archiveStatusFile => File('${_archiveFile.path}.download');

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  Future<void> _cleanupCreatedDirectory() async {
    final downloadPath = path;
    if (!_createdDownloadDirectory || downloadPath == null) return;
    if (LocalManager().isManagedPath(downloadPath)) {
      await Directory(downloadPath).deleteIgnoreError(recursive: true);
    }
    path = null;
    _createdDownloadDirectory = false;
  }

  @override
  void cancel() async {
    _requestBackgroundCancellation();
    _isRunning = false;
    try {
      await _downloader?.stop();
      try {
        await _extracting;
      } catch (_) {
        // The extraction task reports its own error; cancellation still owns
        // the cleanup that follows.
      }
      if (_createdDownloadDirectory &&
          path != null &&
          LocalManager().isManagedPath(path!)) {
        await Directory(path!).deleteIgnoreError(recursive: true);
      }
      await _archiveFile.deleteIgnoreError();
      await _archiveStatusFile.deleteIgnoreError();
      await Directory(
        FilePath.join(App.cachePath, 'archive_staging_$_taskKey'),
      ).deleteIgnoreError(recursive: true);
      path = null;
      LocalManager().removeTask(this);
    } catch (error) {
      _backgroundTask?.addError(error.toString());
      rethrow;
    } finally {
      _finishBackgroundCancellation();
    }
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _resumeRequested = false;
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  int get completedUnits => _currentBytes;
  @override
  int? get totalUnits => _expectedBytes > 0 ? _expectedBytes : null;

  @override
  void resume() {
    _runSerialized(_resume, _setError);
  }

  Future<void> _resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    _message = "Downloading...";
    trackBackgroundTask();
    notifyListeners();

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      final existed = await dir.exists();
      if (!existed) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
      _createdDownloadDirectory = !existed;
    }

    if (path == null || !LocalManager().isManagedPath(path!)) {
      _setError("Error: Download path is outside local storage");
      return;
    }

    final archiveFile = _archiveFile;

    Log.info("Download", "Downloading ${MyLogInterceptor.safeUrl(archiveUrl)}");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      await _cleanupCreatedDirectory();
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      await _cleanupCreatedDirectory();
      _setError("Error: Download failed");
      return;
    }

    try {
      _message = 'Extracting archive...';
      notifyListeners();
      final extracting = _extractArchive(archiveFile.path, path!, _taskKey);
      _extracting = extracting;
      await extracting;
    } catch (e) {
      await _cleanupCreatedDirectory();
      _setError("Failed to extract archive: $e");
      return;
    } finally {
      _extracting = null;
    }

    if (!_isRunning) return;
    await archiveFile.deleteIgnoreError();

    await LocalManager().completeTask(this);
    _isRunning = false;
  }

  static Future<void> _extractArchive(
    String archive,
    String outDir,
    String taskKey,
  ) async {
    if (!LocalManager().isManagedPath(outDir)) {
      throw const FileSystemException(
        'Refusing to publish archive outside local storage',
      );
    }
    final staging = Directory(
      FilePath.join(App.cachePath, 'archive_staging_$taskKey'),
    );
    try {
      await ArchiveSecurity.extract(File(archive), staging);
      await copyDirectoryIsolate(staging, Directory(outDir));
    } finally {
      await staging.deleteIgnoreError(recursive: true);
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    final comic = ComicDetails.fromJson(json["comic"]);
    if (ComicSource.find(comic.sourceKey) == null) return null;
    return ArchiveDownloadTask(json["archiveUrl"], comic)
      ..path = DownloadTask.restoreManagedPath(json["path"]);
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  int _countPages() {
    try {
      const imageExtensions = {
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'jpe',
        'avif',
        'bmp',
      };
      return Directory(path!).listSync(recursive: true).whereType<File>().where(
        (file) {
          final name = file.name.toLowerCase();
          return !name.startsWith('cover.') &&
              imageExtensions.contains(file.extension.toLowerCase());
        },
      ).length;
    } catch (_) {
      return 0;
    }
  }

  @override
  LocalComic toLocalComic() {
    final pageCount = _countPages();
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
      language: comic.language,
      pageCount: pageCount > 0 ? pageCount : null,
    );
  }
}
