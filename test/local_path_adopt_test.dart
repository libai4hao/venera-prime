import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  late Directory temp;
  late Directory oldRoot;
  late LocalManager manager;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local_path_adopt_test');
    oldRoot = Directory('${temp.path}/old_root')..createSync();
    App.dataPath = temp.path;
    File('${temp.path}/local_path').writeAsStringSync(oldRoot.path);
    manager = LocalManager();
    manager.close();
    await manager.init();
  });

  tearDown(() {
    manager.close();
    temp.deleteSync(recursive: true);
  });

  /// Insert one comic row plus its files, mirroring what a download writes.
  Future<LocalComic> writeComic(String folderName, {required bool absolute}) async {
    final dir = Directory('${oldRoot.path}/$folderName')..createSync();
    File('${dir.path}/cover.jpg').writeAsStringSync('cover');
    final comic = LocalComic(
      id: manager.findValidId(ComicType.local),
      title: folderName,
      subtitle: 'by author',
      tags: [],
      directory: absolute ? '${oldRoot.path}/$folderName' : folderName,
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime.now(),
      managedByApp: true,
    );
    await manager.add(comic);
    return comic;
  }

  test('take over a non-empty directory when adoptExisting is true', () async {
    final comic = await writeComic('ComicA', absolute: false);

    final newPath = '${temp.path}/new_root/existing';
    Directory(newPath).createSync(recursive: true);
    File('${newPath}/keep.txt').writeAsStringSync('keep');

    final error = await manager.setNewPath(newPath, adoptExisting: true);

    expect(error, isNull);
    expect(manager.path, newPath);
    expect(File('${newPath}/keep.txt').existsSync(), isTrue);
    // pre-existing files in the target are kept
    expect(Directory('${newPath}/ComicA').existsSync(), isFalse);
    // nothing was copied from the old root
    final stored = manager.find(comic.id, ComicType.local)!;
    expect(File(stored.baseDir).existsSync(), isFalse);
    expect(File('${oldRoot.path}/ComicA/cover.jpg').existsSync(), isTrue);
    // the stored path now resolves against the new root
    expect(File('$newPath/ComicA/cover.jpg').existsSync(), isFalse);
    expect(stored.directory, 'ComicA');
  });

  test('still refuse a non-empty directory when adoptExisting is false',
      () async {
    await writeComic('ComicA', absolute: false);
    final newRoot = Directory('${temp.path}/new_root')..createSync();
    File('${newRoot.path}/seed.txt').writeAsStringSync('x');

    final error = await manager.setNewPath(newRoot.path);

    expect(error, isNotNull);
    expect(manager.path, oldRoot.path);
  });

  test('still refuse a path inside the current storage path', () async {
    await writeComic('ComicA', absolute: false);
    final nested = Directory('${oldRoot.path}/sub')..createSync();

    final error = await manager.setNewPath(nested.path, adoptExisting: true);

    expect(error, isNotNull);
    expect(manager.path, oldRoot.path);
  });

  test('rewrite absolute directories that point into the old root', () async {
    final comic = await writeComic('ComicA', absolute: true);
    final newRoot = Directory('${temp.path}/new_root')..createSync();

    final error = await manager.setNewPath(newRoot.path);

    expect(error, isNull);
    final after = manager.find(comic.id, ComicType.local)!;
    expect(after.directory, 'ComicA');
    expect(File('${newRoot.path}/ComicA/cover.jpg').existsSync(), isTrue);
    expect(after.isMissing, isFalse);
  });

  test('leave directories outside the old root untouched', () async {
    final elsewhere =
        Directory('${temp.path}/elsewhere/ComicA')..createSync(recursive: true);
    File('${elsewhere.path}/cover.jpg').writeAsStringSync('cover');
    final comic = LocalComic(
      id: manager.findValidId(ComicType.local),
      title: 'ComicA',
      subtitle: 'by author',
      tags: [],
      directory: elsewhere.path,
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime.now(),
      managedByApp: true,
    );
    await manager.add(comic);
    final newRoot = Directory('${temp.path}/new_root')..createSync();

    final error = await manager.setNewPath(newRoot.path);

    expect(error, isNull);
    final after = manager.find(comic.id, ComicType.local)!;
    expect(after.directory, elsewhere.path);
  });
}
