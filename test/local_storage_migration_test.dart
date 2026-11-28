import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

class _LockedFile implements File {
  _LockedFile(this.actual);
  final File actual;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw FileSystemException(
        'File locked by another process',
        path,
        const OSError('sharing violation', 32),
      );
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _LockedDirectory implements Directory {
  _LockedDirectory(this.actual);
  final Directory actual;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => actual
      .listSync(recursive: recursive, followLinks: followLinks)
      .map((e) => e is File ? _LockedFile(e) : e)
      .toList();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final class _LockedOverrides extends IOOverrides {
  _LockedOverrides(this.locked);
  final String locked;
  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return path == locked ? _LockedDirectory(directory) : directory;
  }
}

void main() {
  test(
    'committed storage migration survives Windows-style source cleanup failure',
    () async {
      final root = await Directory.systemTemp.createTemp('storage-move-');
      final old = Directory('${root.path}/old')..createSync();
      final target = Directory('${root.path}/new')..createSync();
      final bytes = List<int>.generate(200000, (i) => i % 251);
      File('${old.path}/page.jpg').writeAsBytesSync(bytes);
      App.dataPath = root.path;
      File('${root.path}/local_path').writeAsStringSync(old.path);
      final manager = LocalManager();
      manager.close();
      try {
        await manager.init();
        await IOOverrides.runWithIOOverrides(() async {
          expect(await manager.setNewPath(target.path), isNull);
        }, _LockedOverrides(old.path));
        expect(manager.path, target.path);
        expect(File('${root.path}/local_path').readAsStringSync(), target.path);
        expect(File('${target.path}/page.jpg').readAsBytesSync(), bytes);
        expect(File('${old.path}/page.jpg').existsSync(), isTrue);
        manager.close();
        await manager.init();
        expect(manager.path, target.path);
      } finally {
        manager.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('an empty target still copies the library', () async {
    final root = await Directory.systemTemp.createTemp('storage-copy-');
    final old = Directory('${root.path}/old')..createSync();
    final target = Directory('${root.path}/new')..createSync();
    final comicDir = Directory('${old.path}/comic')..createSync();
    File('${comicDir.path}/1.jpg').writeAsStringSync('old');
    App.dataPath = root.path;
    File('${root.path}/local_path').writeAsStringSync(old.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    try {
      await manager.add(
        LocalComic(
          id: '1',
          title: 'Comic',
          subtitle: '',
          tags: const [],
          directory: 'comic',
          chapters: null,
          cover: '1.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final result = await manager.changeStoragePath(target.path);
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(manager.path, target.path);
      expect(File('${target.path}/comic/1.jpg').readAsStringSync(), 'old');
      // The old copy is cleaned up once the new path is committed.
      expect(File('${old.path}/comic/1.jpg').existsSync(), isFalse);
      expect(manager.find('1', ComicType.local)!.managedByApp, isTrue);
    } finally {
      manager.close();
      await root.delete(recursive: true);
    }
  });

  test('a non-empty target is adopted without copying', () async {
    final root = await Directory.systemTemp.createTemp('storage-adopt-');
    final old = Directory('${root.path}/old')..createSync();
    final target = Directory('${root.path}/new')..createSync();
    final oldComic = Directory('${old.path}/comic')..createSync();
    File('${oldComic.path}/1.jpg').writeAsStringSync('old');
    final newComic = Directory('${target.path}/comic')..createSync();
    File('${newComic.path}/1.jpg').writeAsStringSync('new');
    Directory('${target.path}/extra').createSync();
    App.dataPath = root.path;
    File('${root.path}/local_path').writeAsStringSync(old.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    try {
      await manager.add(
        LocalComic(
          id: '1',
          title: 'Comic',
          subtitle: '',
          tags: const [],
          directory: 'comic',
          chapters: null,
          cover: '1.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final result = await manager.changeStoragePath(target.path);
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(manager.path, target.path);
      expect(File('${root.path}/local_path').readAsStringSync(), target.path);
      expect(File('${newComic.path}/1.jpg').readAsStringSync(), 'new');
      // Adoption never copies or deletes the previous root.
      expect(File('${oldComic.path}/1.jpg').readAsStringSync(), 'old');
      expect(File('${target.path}/comic/1.jpg').existsSync(), isTrue);

      final conflict = result.data.conflicts.single;
      expect(
        conflict.duplicatePath.replaceAll('\\', '/'),
        oldComic.path.replaceAll('\\', '/'),
      );
      final stored = manager.find('1', ComicType.local)!;
      expect(stored.directory, 'comic');
      expect(stored.managedByApp, isTrue);
      expect(
        stored.baseDir.replaceAll('\\', '/'),
        newComic.path.replaceAll('\\', '/'),
      );
    } finally {
      manager.close();
      await root.delete(recursive: true);
    }
  });

  test('adoption rolls back when the new path cannot be persisted', () async {
    final root = await Directory.systemTemp.createTemp('storage-rollback-');
    final old = Directory('${root.path}/old')..createSync();
    final target = Directory('${root.path}/new')..createSync();
    final oldComic = Directory('${old.path}/comic')..createSync();
    File('${oldComic.path}/1.jpg').writeAsStringSync('old');
    File('${target.path}/keep.jpg').writeAsStringSync('keep');
    App.dataPath = root.path;
    final pathFile = File('${root.path}/local_path')
      ..writeAsStringSync(old.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    pathFile.deleteSync();
    Directory(pathFile.path).createSync();
    try {
      await manager.add(
        LocalComic(
          id: '1',
          title: 'Comic',
          subtitle: '',
          tags: const [],
          directory: 'comic',
          chapters: null,
          cover: '1.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final result = await manager.adoptExistingPath(target.path);
      expect(result.success, isFalse);
      expect(result.errorMessage, isNotNull);
      expect(manager.path, old.path);

      final stored = manager.find('1', ComicType.local)!;
      expect(stored.directory, 'comic');
      expect(File('${oldComic.path}/1.jpg').readAsStringSync(), 'old');
      expect(File('${target.path}/keep.jpg').existsSync(), isTrue);
    } finally {
      manager.close();
      await root.delete(recursive: true);
    }
  });
}
