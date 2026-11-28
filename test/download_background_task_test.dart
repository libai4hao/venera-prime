import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';

class _Source implements ComicSource {
  @override
  final String key = 'background-download-fixture';
  final started = Completer<void>();
  final response = Completer<Res<ComicDetails>>();
  @override
  LoadComicFunc get loadComicInfo => (_) {
    if (!started.isCompleted) started.complete();
    return response.future;
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Source source;
  final manager = LocalManager();

  ComicDetails comic() => ComicDetails.fromJson({
    'comicId': 'fixture',
    'sourceKey': source.key,
    'title': 'Fixture',
    'cover': '',
    'tags': <String, dynamic>{},
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('background-download-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    final local = Directory('${root.path}/local')..createSync();
    File('${root.path}/local_path').writeAsStringSync(local.path);
    manager.close();
    manager.downloadingTasks.clear();
    await manager.init();
    source = _Source();
    ComicSourceManager().add(source);
  });
  tearDown(() async {
    for (final task in List.of(manager.downloadingTasks)) {
      task.cancel();
    }
    if (!source.response.isCompleted) source.response.complete(Res(comic()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await manager.saveCurrentDownloadingTasks();
    manager.close();
    ComicSourceManager().remove(source.key);
    await root.delete(recursive: true);
  });

  for (final matched in [true, false]) {
    test(
      'restored cancel checks directory ownership (matched=$matched)',
      () async {
        final dir = Directory('${manager.path}/fixture')..createSync();
        final file = File('${dir.path}/0.jpg')..writeAsBytesSync([1]);
        final original = ImagesDownloadTask(
          source: source,
          comicId: 'fixture',
          comic: comic(),
        );
        File('${dir.path}/.venera_download.json').writeAsStringSync(
          jsonEncode({
            'owner': matched ? 'saved' : 'different',
            'id': 'fixture',
            'type': original.comicType.value,
          }),
        );
        final restored = ImagesDownloadTask.fromJson({
          ...original.toJson(),
          'path': dir.path,
          'createdDirectory': true,
          'owner': 'saved',
        })!;
        manager.downloadingTasks.add(restored);
        restored.cancel();
        for (
          var i = 0;
          i < 100 && manager.downloadingTasks.contains(restored);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(manager.downloadingTasks, isEmpty);
        expect(file.existsSync(), !matched);
      },
    );
  }

  test(
    'cancel after restoring a shared directory removes only owned pages',
    () async {
      final dir = Directory('${manager.path}/comic')..createSync();
      final chapter = Directory('${dir.path}/one')..createSync();
      final old = File('${chapter.path}/0.png')..writeAsBytesSync([1]);
      final added = File('${chapter.path}/1.png')..writeAsBytesSync([2]);
      final marker = File('${dir.path}/.venera_download.json')
        ..writeAsStringSync('{}');
      final task = ImagesDownloadTask.fromJson({
        ...ImagesDownloadTask(
          source: source,
          comicId: 'fixture',
          comic: comic(),
          chapters: ['one'],
        ).toJson(),
        'path': dir.path,
        'createdFiles': [added.path],
      })!;
      manager.downloadingTasks.add(task);
      expect(await manager.abandonedDownloads(), isEmpty);
      expect((await manager.refresh()).discovered, 0);
      task.cancel();
      for (var i = 0; i < 100 && manager.downloadingTasks.contains(task); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(added.existsSync(), false);
      expect(old.readAsBytesSync(), [1]);
      expect(marker.existsSync(), true);
      expect((await manager.abandonedDownloads()).single.path, dir.path);
      expect((await manager.refresh()).discovered, 0);
      await manager.deleteAbandonedDownload(dir);
      expect(dir.existsSync(), false);
    },
  );

  test(
    'queue task stays active when paused and cancels through task center',
    () async {
      final download = ImagesDownloadTask(
        source: source,
        comicId: 'fixture',
        comicTitle: 'Fixture',
      );
      manager.addTask(download);
      await source.started.future;
      final tracked = BackgroundTasks.instance.latest(
        download.backgroundTaskKey,
      )!;
      expect(tracked.isRunning, isTrue);
      download.pause();
      expect(tracked.isRunning, isTrue);
      expect(tracked.message, 'Paused');
      tracked.requestCancel();
      source.response.complete(Res(comic()));
      for (var i = 0; i < 50 && tracked.isRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(tracked.status, BackgroundTaskStatus.cancelled);
      expect(tracked.onCancel, isNull);
      expect(manager.downloadingTasks, isEmpty);
    },
  );

  test(
    'direct resume reports errors and retry creates a new tracked attempt',
    () async {
      final download = ImagesDownloadTask(
        source: source,
        comicId: 'fixture',
        comic: comic(),
      );
      download.path =
          root.path; // Outside the configured managed comic storage.
      Future<BackgroundTask> attempt() async {
        download.resume();
        for (var i = 0; i < 50 && !download.isError; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(download.isError, isTrue);
        final tracked = BackgroundTasks.instance.latest(
          download.backgroundTaskKey,
        )!;
        expect(tracked.status, BackgroundTaskStatus.failed);
        expect(tracked.onCancel, isNull);
        expect(tracked.errors, isNotEmpty);
        return tracked;
      }

      final first = await attempt();
      final retry = await attempt();
      expect(retry.id, greaterThan(first.id));
      download.dispose();
    },
  );

  test(
    'restored download queue appears without starting network requests',
    () async {
      manager.downloadingTasks.add(
        ImagesDownloadTask(source: source, comicId: 'restored', comic: comic()),
      );
      await manager.saveCurrentDownloadingTasks();
      manager.downloadingTasks.clear();
      manager.restoreDownloadingTasks();
      final restored = manager.downloadingTasks.single;
      final tracked = BackgroundTasks.instance.latest(
        restored.backgroundTaskKey,
      )!;
      expect(tracked.isRunning, isTrue);
      expect(tracked.message, 'Queued');
      expect(restored.isPaused, isTrue);
      expect(source.started.isCompleted, isFalse);
    },
  );
}
