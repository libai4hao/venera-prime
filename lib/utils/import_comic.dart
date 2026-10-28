import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/local_restore_conflicts_page.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:path/path.dart' as path_utils;
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';
import 'cbz.dart';
import 'io.dart';
import 'natural_sort.dart';

String _normalizeComicTitle(String title) {
  return title.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

class LocalDownloadsRestoreResult {
  final bool success;
  final String? error;
  final int imported;
  final int skipped;
  final int invalid;
  final String? previousRoot;
  final List<LocalRestoreConflict> conflicts;

  const LocalDownloadsRestoreResult({
    required this.success,
    this.error,
    this.imported = 0,
    this.skipped = 0,
    this.invalid = 0,
    this.previousRoot,
    this.conflicts = const [],
  });
}

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  static Future<void> _libraryWork = Future.value();

  /// Import, rescan and path changes all mutate the same local library.
  /// Keep them ordered even when their progress views are minimized.
  static Future<T> withLibraryLock<T>(Future<T> Function() action) {
    final operation = _libraryWork.then((_) => action());
    _libraryWork = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  static bool _importing = false;
  static bool get isImporting => _importing;

  Future<bool> _exclusive(Future<bool> Function() action) async {
    if (_importing) {
      App.rootContext.showMessage(
        message: 'A comic import is already running'.tl,
      );
      return false;
    }
    _importing = true;
    try {
      return await withLibraryLock(action);
    } finally {
      _importing = false;
    }
  }

  Future<bool> cbz() => _exclusive(_cbz);
  Future<bool> multipleCbz() => _exclusive(_multipleCbz);
  Future<bool> ehViewer() => _exclusive(_ehViewer);
  Future<bool> directory(bool single) => _exclusive(() => _directory(single));
  Future<bool> localDownloads() => _exclusive(_localDownloads);

  Future<bool> _cbz() async {
    final file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    if (file == null) return false;
    final controller = showLoadingDialog(
      App.rootContext,
      allowCancel: false,
      allowBackground: true,
      message: 'Importing'.tl,
    );
    try {
      final comic = await CBZ.import(File(file.path));
      return await registerComics(
        {
          selectedFolder: [comic],
        },
        false,
        controller: controller,
      );
    } catch (error, stack) {
      controller.fail(error);
      Log.error('Import Comic', error, stack);
      App.rootContext.showMessage(message: error.toString());
      return false;
    } finally {
      controller.close();
    }
  }

  Future<bool> _multipleCbz() async {
    final picker = DirectoryPicker();
    final dir = await picker.pickDirectory(directAccess: true);
    if (dir == null) return false;
    final controller = showLoadingDialog(
      App.rootContext,
      allowCancel: false,
      allowBackground: true,
      message: 'Importing'.tl,
      withProgress: true,
    );
    try {
      const supported = ['cbz', 'zip', '7z', 'cb7'];
      final files = (await dir.list().toList())
          .whereType<File>()
          .where((f) => supported.contains(f.extension.toLowerCase()))
          .toList();
      final comics = <LocalComic>[];
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        try {
          comics.add(await CBZ.import(file));
        } catch (error, stack) {
          controller.addError('${file.name}: $error');
          Log.error('Import Comic', error, stack);
        }
        controller.setProgress((i + 1) / files.length);
      }
      if (comics.isEmpty) {
        controller.addError('No valid comics found'.tl);
        App.rootContext.showMessage(message: 'No valid comics found'.tl);
      }
      return await registerComics(
        {selectedFolder: comics},
        false,
        controller: controller,
      );
    } catch (error, stack) {
      controller.fail(error);
      Log.error('Import Comic', error, stack);
      return false;
    } finally {
      controller.close();
    }
  }

  Future<bool> _ehViewer() async {
    var dbFile = await selectFile(ext: ['db']);
    final picker = DirectoryPicker();
    final comicSrc = await picker.pickDirectory();
    Map<String?, List<LocalComic>> imported = {};
    if (dbFile == null || comicSrc == null) {
      return false;
    }

    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      allowBackground: true,
      message: 'Importing'.tl,
      onCancel: () {
        cancelled = true;
      },
    );

    sql.Database? openedDatabase;
    try {
      final db = openedDatabase = sql.sqlite3.open(dbFile.path);

      Future<List<LocalComic>> validateComics(List<sql.Row> comics) async {
        List<LocalComic> imported = [];
        final sourceRoot = path_utils.canonicalize(comicSrc.path);
        for (var comic in comics) {
          if (cancelled) {
            return imported;
          }
          final rawDirectory = comic['DIRNAME'];
          if (rawDirectory is! String || rawDirectory.isEmpty) continue;
          final candidatePath = path_utils.canonicalize(
            FilePath.join(comicSrc.path, rawDirectory),
          );
          if (candidatePath == sourceRoot ||
              !path_utils.isWithin(sourceRoot, candidatePath)) {
            Log.warning(
              "Import Comic",
              "Ignoring EhViewer directory outside the selected root",
            );
            continue;
          }
          var comicDir = Directory(candidatePath);
          String titleJP = comic['TITLE_JPN'] == null
              ? ""
              : comic['TITLE_JPN'] as String;
          String title = titleJP == "" ? comic['TITLE'] as String : titleJP;
          int timeStamp = comic['TIME'] as int;
          DateTime downloadTime = timeStamp != 0
              ? DateTime.fromMillisecondsSinceEpoch(timeStamp)
              : DateTime.now();
          var comicObj = await _checkSingleComic(
            comicDir,
            title: title,
            tags: [
              //1 >> x
              [
                "MISC",
                "DOUJINSHI",
                "MANGA",
                "ARTISTCG",
                "GAMECG",
                "IMAGE SET",
                "COSPLAY",
                "ASIAN PORN",
                "NON-H",
                "WESTERN",
              ][(log(comic['CATEGORY'] as int) / ln2).floor()],
            ],
            createTime: downloadTime,
          );
          if (comicObj == null) {
            continue;
          }
          imported.add(comicObj);
        }
        return imported;
      }

      var tags = <String>[""];
      tags.addAll(
        db
            .select("""
            SELECT * FROM DOWNLOAD_LABELS LB
            ORDER BY  LB.TIME DESC;
          """)
            .map((r) => r['LABEL'] as String)
            .toList(),
      );

      for (var tag in tags) {
        if (cancelled) {
          break;
        }
        var folderName = tag == '' ? '(EhViewer)Default'.tl : '(EhViewer)$tag';
        final comicList = db.select("""
              SELECT * 
              FROM DOWNLOAD_DIRNAME DN
              LEFT JOIN DOWNLOADS DL
              ON DL.GID = DN.GID
              WHERE DL.LABEL ${tag == '' ? 'IS NULL' : '= ?'} AND DL.STATE = 3
              ORDER BY DL.TIME DESC
            """, tag == '' ? const [] : [tag]).toList();

        var validComics = await validateComics(comicList);
        imported[folderName] = validComics;
        if (validComics.isNotEmpty &&
            !LocalFavoritesManager().existsFolder(folderName)) {
          LocalFavoritesManager().createFolder(folderName);
        }
      }
      db.dispose();
      openedDatabase = null;
      //Android specific
      var cache = FilePath.join(App.cachePath, dbFile.name);
      await File(cache).deleteIgnoreError();
    } catch (e, s) {
      controller.fail(e);
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return false;
    } finally {
      openedDatabase?.dispose();
    }
    if (cancelled) {
      controller.close();
      return false;
    }
    return registerComics(
      imported,
      copyToLocal,
      controller: controller,
      isCancelled: () => cancelled,
    );
  }

  Future<bool> _directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) {
      return false;
    }
    Map<String?, List<LocalComic>> imported = {selectedFolder: []};
    final controller = showLoadingDialog(
      App.rootContext,
      allowCancel: false,
      allowBackground: true,
      message: 'Importing'.tl,
    );
    try {
      if (single) {
        var result = await _checkSingleComic(path);
        if (result != null) {
          imported[selectedFolder]!.add(result);
        } else {
          controller.fail('Invalid Comic'.tl);
          App.rootContext.showMessage(message: "Invalid Comic".tl);
          return false;
        }
      } else {
        await for (var entry in path.list()) {
          if (entry is Directory) {
            var result = await _checkSingleComic(entry);
            if (result != null) {
              imported[selectedFolder]!.add(result);
            }
          }
        }
      }
    } catch (e, s) {
      controller.fail(e);
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return false;
    }
    return registerComics(imported, copyToLocal, controller: controller);
  }

  Future<bool> _localDownloads() async {
    final picker = DirectoryPicker();
    final legacyDirectory = await picker.pickDirectory(persistAccess: true);
    if (legacyDirectory == null) {
      return false;
    }
    final result = await restoreLocalDownloads(legacyDirectory);
    if (!result.success) {
      return false;
    }
    if (result.conflicts.isNotEmpty && App.rootContext.mounted) {
      await App.rootContext.to(
        () => LocalRestoreConflictsPage(
          conflicts: result.conflicts,
          previousRoot: result.previousRoot!,
        ),
      );
    }
    return true;
  }

  /// Adopts [legacyDirectory] as the local storage path without copying files
  /// and imports only comics that are missing from the current library.
  Future<LocalDownloadsRestoreResult> restoreLocalDownloads(
    Directory legacyDirectory, {
    bool showUi = true,
  }) async {
    final previousRoot = LocalManager().path;
    final legacyRoot = legacyDirectory.path;
    var cancelled = false;
    LoadingDialogController? controller;
    if (showUi) {
      controller = showLoadingDialog(
        App.rootContext,
        allowBackground: true,
        message: 'Importing'.tl,
        onCancel: () {
          cancelled = true;
        },
      );
    }

    LocalDownloadsRestoreResult failure({String? error}) {
      return LocalDownloadsRestoreResult(
        success: false,
        error: error,
        previousRoot: previousRoot,
      );
    }

    try {
      if (!await legacyDirectory.exists()) {
        final message = 'Local path not found'.tl;
        controller?.fail(message);
        if (showUi) App.rootContext.showMessage(message: message);
        return failure(error: message);
      }

      final existing = LocalManager().getComics(LocalSortType.timeDesc);
      final existingPaths = existing
          .map((comic) => path_utils.canonicalize(comic.baseDir))
          .toSet();
      final existingTitles = existing
          .map((comic) => _normalizeComicTitle(comic.title))
          .where((title) => title.isNotEmpty)
          .toSet();
      final existingDirectories = existing
          .map((comic) => path_utils.basename(comic.directory))
          .toSet();
      final previousRootCanonical = path_utils.canonicalize(previousRoot);
      final legacyRootCanonical = path_utils.canonicalize(legacyRoot);
      final toImport = <LocalComic>[];
      final conflicts = <LocalRestoreConflict>[];
      var skipped = 0;
      var invalid = 0;

      await for (final entry in legacyDirectory.list(followLinks: false)) {
        if (cancelled) {
          break;
        }
        if (entry is! Directory ||
            FileSystemEntity.typeSync(entry.path, followLinks: false) ==
                FileSystemEntityType.link) {
          continue;
        }
        final result = await _checkSingleComic(
          entry,
          createTime: (await entry.stat()).modified,
          useRelativePath: true,
          checkExistingByName: false,
          useMetadata: true,
        );
        if (result == null) {
          invalid++;
          continue;
        }
        final title = _normalizeComicTitle(result.title);
        final canonicalPath = path_utils.canonicalize(entry.path);
        if (existingPaths.contains(canonicalPath) ||
            existingTitles.contains(title) ||
            existingDirectories.contains(entry.name)) {
          skipped++;
          continue;
        }
        toImport.add(result);
        if (previousRootCanonical != legacyRootCanonical) {
          final duplicate = Directory(FilePath.join(previousRoot, entry.name));
          if (duplicate.existsSync()) {
            conflicts.add(
              LocalRestoreConflict(
                title: result.title,
                activePath: entry.path,
                duplicatePath: duplicate.path,
              ),
            );
          }
        }
      }

      if (cancelled) {
        controller?.close();
        return failure();
      }

      final adoption = await LocalManager().adoptExistingPath(legacyRoot);
      if (!adoption.success) {
        final message = adoption.error ?? 'Failed to change local path'.tl;
        controller?.fail(message);
        if (showUi) App.rootContext.showMessage(message: message);
        return failure(error: message);
      }
      for (final conflict in adoption.conflicts) {
        final duplicate = path_utils.canonicalize(conflict.duplicatePath);
        if (conflicts.any(
          (item) => path_utils.canonicalize(item.duplicatePath) == duplicate,
        )) {
          continue;
        }
        conflicts.add(conflict);
      }

      var imported = 0;
      if (toImport.isNotEmpty) {
        final registered = await registerComics(
          {null: toImport},
          false,
          controller: controller,
          isCancelled: () => cancelled,
          showUi: false,
        );
        if (!registered) {
          return failure(error: 'Failed to register comics'.tl);
        }
        imported = toImport.length;
      }

      final message = imported == 0
          ? 'No new comics found. Storage path updated.'.tl
          : 'Imported @a comics, skipped @b existing comics'.tlParams({
              'a': imported,
              'b': skipped,
            });
      controller?.setMessage(message);
      if (showUi) App.rootContext.showMessage(message: message);
      return LocalDownloadsRestoreResult(
        success: true,
        imported: imported,
        skipped: skipped,
        invalid: invalid,
        previousRoot: previousRoot,
        conflicts: conflicts,
      );
    } catch (e, s) {
      controller?.fail(e);
      Log.error('Import Comic', e.toString(), s);
      if (showUi) App.rootContext.showMessage(message: e.toString());
      return failure(error: e.toString());
    } finally {
      controller?.close();
    }
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(
    Directory directory, {
    String? id,
    String? title,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
    bool checkExistingByName = true,
    bool useMetadata = false,
  }) async {
    if (!(await directory.exists())) return null;
    final metadata = useMetadata
        ? await LocalManager().readLocalMetadata(directory)
        : null;
    var name = title ?? metadata?.title ?? directory.name;
    if (checkExistingByName && LocalManager().findByName(name) != null) {
      Log.info("Import Comic", "Comic already exists: $name");
      return null;
    }
    bool hasChapters = false;
    var chapters = <String>[];
    var coverPath = ''; // relative path to the cover image
    var fileList = <String>[];
    var rootPageCount = 0;
    var chapterPageCount = 0;
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
    await for (var entry in directory.list()) {
      if (entry is Directory) {
        var chapterHasImages = false;
        var chapterPages = 0;
        await for (var file in entry.list()) {
          if (file is Directory) {
            Log.info(
              "Import Comic",
              "Invalid Chapter: ${entry.name}\nA directory is found in the chapter directory.",
            );
            return null;
          }
          if (file is File &&
              imageExtensions.contains(file.extension.toLowerCase())) {
            chapterHasImages = true;
            if (!file.name.toLowerCase().startsWith('cover.')) {
              chapterPages++;
            }
          }
        }
        if (chapterHasImages) {
          hasChapters = true;
          chapters.add(entry.name);
          chapterPageCount += chapterPages;
        }
      } else if (entry is File) {
        if (imageExtensions.contains(entry.extension.toLowerCase())) {
          fileList.add(entry.name);
          if (!entry.name.toLowerCase().startsWith('cover.')) {
            rootPageCount++;
          }
        }
      }
    }

    if (fileList.isEmpty && !hasChapters) {
      return null;
    }

    fileList.sort(naturalCompare);
    if (fileList.isNotEmpty) {
      coverPath =
          fileList.firstWhereOrNull(
            (l) => l.toLowerCase().startsWith('cover'),
          ) ??
          fileList.first;
    }

    chapters.sort(naturalCompare);
    if (hasChapters && coverPath == '') {
      // use the first image in the first chapter as the cover
      var firstChapter = Directory('${directory.path}/${chapters.first}');
      await for (var entry in firstChapter.list()) {
        if (entry is File &&
            imageExtensions.contains(entry.extension.toLowerCase())) {
          coverPath = entry.name;
          break;
        }
      }
    }
    if (coverPath == '') {
      Log.info("Import Comic", "Invalid Comic: $name\nNo cover image found.");
      return null;
    }
    var directoryPath = useRelativePath ? directory.name : directory.path;
    final pageCount = hasChapters ? chapterPageCount : rootPageCount;
    return LocalComic(
      id: id ?? '0',
      title: name,
      subtitle: subtitle ?? metadata?.author ?? '',
      descriptionText: metadata?.description ?? '',
      tags: tags ?? metadata?.tags ?? [],
      directory: directoryPath,
      chapters: hasChapters
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: coverPath,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime ?? DateTime.now(),
      language: metadata?.language,
      pageCount: pageCount > 0 ? pageCount : null,
    );
  }

  static Future<Map<String, String>> _copyDirectories(
    Map<String, dynamic> data,
  ) async {
    return overrideIO(() async {
      var toBeCopied = data['toBeCopied'] as List<String>;
      var destination = data['destination'] as String;
      Map<String, String> result = {};
      for (var dir in toBeCopied) {
        var source = Directory(dir);
        var dest = Directory("$destination/${source.name}");
        if (dest.existsSync()) {
          // The destination directory already exists, and it is not managed by the app.
          // Rename the old directory to avoid conflicts.
          Log.info(
            "Import Comic",
            "Directory already exists: ${source.name}\nRenaming the old directory.",
          );
          dest.renameSync(
            findValidDirectoryName(dest.parent.path, "${dest.path}_old"),
          );
        }
        dest.createSync();
        await copyDirectory(source, dest);
        result[source.path] = dest.path;
      }
      return result;
    });
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
    Map<String?, List<LocalComic>> comics, {
    LoadingDialogController? controller,
  }) async {
    var destPath = LocalManager().path;
    final canonicalDest = path_utils.canonicalize(destPath);
    bool isInLocalStorage(LocalComic comic) {
      final candidate = path_utils.canonicalize(comic.baseDir);
      return candidate != canonicalDest &&
          path_utils.isWithin(canonicalDest, candidate);
    }

    Map<String?, List<LocalComic>> result = {};
    for (var favoriteFolder in comics.keys) {
      result[favoriteFolder] = comics[favoriteFolder]!
          .where(isInLocalStorage)
          .toList();
      comics[favoriteFolder]!.removeWhere(isInLocalStorage);

      if (comics[favoriteFolder]!.isEmpty) {
        continue;
      }

      try {
        // copy the comics to the local directory
        var pathMap = await compute<Map<String, dynamic>, Map<String, String>>(
          _copyDirectories,
          {
            'toBeCopied': comics[favoriteFolder]!
                .map((e) => e.directory)
                .toList(),
            'destination': destPath,
          },
        );
        //Construct a new object since LocalComic.directory is a final String
        for (var c in comics[favoriteFolder]!) {
          result[favoriteFolder]!.add(
            LocalComic(
              id: c.id,
              title: c.title,
              subtitle: c.subtitle,
              descriptionText: c.descriptionText,
              tags: c.tags,
              directory: pathMap[c.directory]!,
              chapters: c.chapters,
              cover: c.cover,
              comicType: c.comicType,
              downloadedChapters: c.downloadedChapters,
              createdAt: c.createdAt,
              managedByApp: true,
              language: c.language,
              pageCount: c.pageCount,
            ),
          );
        }
      } catch (e, s) {
        controller?.addError(e);
        App.rootContext.showMessage(message: "Failed to copy comics".tl);
        Log.error("Import Comic", e.toString(), s);
        return result;
      }
    }
    return result;
  }

  Future<bool> registerComics(
    Map<String?, List<LocalComic>> importedComics,
    bool copy, {
    LoadingDialogController? controller,
    bool Function()? isCancelled,
    bool showUi = true,
  }) async {
    controller ??= showUi
        ? showLoadingDialog(
            App.rootContext,
            allowCancel: false,
            allowBackground: true,
            message: 'Importing'.tl,
          )
        : null;
    try {
      if (isCancelled?.call() == true) return false;
      controller?.setProgress(null);
      if (copy) {
        importedComics = await _copyComicsToLocalDir(
          importedComics,
          controller: controller,
        );
      }
      if (isCancelled?.call() == true) return false;
      int importedCount = 0;
      outer:
      for (var folder in importedComics.keys) {
        for (var comic in importedComics[folder]!) {
          if (isCancelled?.call() == true) break outer;
          var id = LocalManager().findValidId(ComicType.local);
          final localRoot = path_utils.canonicalize(LocalManager().path);
          final comicPath = path_utils.canonicalize(comic.baseDir);
          final managed =
              comicPath != localRoot &&
              path_utils.isWithin(localRoot, comicPath);
          final toStore = managed == comic.managedByApp
              ? comic
              : LocalComic(
                  id: comic.id,
                  title: comic.title,
                  subtitle: comic.subtitle,
                  descriptionText: comic.descriptionText,
                  tags: comic.tags,
                  directory: comic.directory,
                  chapters: comic.chapters,
                  cover: comic.cover,
                  comicType: comic.comicType,
                  downloadedChapters: comic.downloadedChapters,
                  createdAt: comic.createdAt,
                  managedByApp: managed,
                  language: comic.language,
                  pageCount: comic.pageCount,
                );
          LocalManager().add(toStore, id);
          importedCount++;
          if (folder != null) {
            LocalFavoritesManager().addComic(
              folder,
              FavoriteItem(
                id: id,
                name: comic.title,
                coverPath: comic.cover,
                author: comic.subtitle,
                type: comic.comicType,
                tags: comic.tags,
                favoriteTime: comic.createdAt,
              ),
            );
          }
        }
      }
      final message = "Imported @a comics".tlParams({'a': importedCount});
      controller?.setMessage(message);
      if (showUi) App.rootContext.showMessage(message: message);
    } catch (e, s) {
      controller?.fail(e);
      if (showUi) {
        App.rootContext.showMessage(message: "Failed to register comics".tl);
      }
      Log.error("Import Comic", e.toString(), s);
      return false;
    } finally {
      controller?.close();
    }
    return true;
  }
}
