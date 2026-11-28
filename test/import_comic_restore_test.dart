import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_utils;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppTranslation.init();
  });

  test('adopts an existing directory without copying files', () async {
    final temp = await Directory.systemTemp.createTemp('venera-restore-');
    final current = Directory(path_utils.join(temp.path, 'current'))
      ..createSync(recursive: true);
    final legacy = Directory(path_utils.join(temp.path, 'legacy'))
      ..createSync(recursive: true);
    App.dataPath = temp.path;
    File(
      path_utils.join(temp.path, 'local_path'),
    ).writeAsStringSync(current.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    _createComic(current, 'duplicate');
    await manager.add(
      LocalComic(
        id: '1',
        title: 'Duplicate',
        subtitle: 'Author',
        tags: const [],
        directory: 'duplicate',
        chapters: null,
        cover: '1.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    _createComic(legacy, 'duplicate');
    _createComic(legacy, 'new-comic', title: 'New Comic', pages: 2);

    try {
      final result = await const ImportComic().restoreLocalDownloads(
        legacy,
        showUi: false,
      );

      expect(result.success, isTrue, reason: result.errorMessage);
      final data = result.data;
      expect(data.imported, 1);
      expect(data.skipped, 1);
      expect(data.invalid, 0);
      expect(manager.path, legacy.path);
      expect(manager.getComics(LocalSortType.timeDesc), hasLength(2));

      final imported = manager.findByName('New Comic');
      expect(imported, isNotNull);
      expect(imported!.directory, 'new-comic');
      expect(imported.managedByApp, isTrue);
      expect(
        path_utils.isWithin(
          path_utils.canonicalize(legacy.path),
          path_utils.canonicalize(imported.baseDir),
        ),
        isTrue,
      );
      expect(
        Directory(path_utils.join(current.path, 'new-comic')).existsSync(),
        isFalse,
      );
      expect(
        Directory(path_utils.join(legacy.path, 'new-comic')).existsSync(),
        isTrue,
      );

      expect(data.conflicts, hasLength(1));
      expect(
        path_utils.canonicalize(data.conflicts.single.duplicatePath),
        path_utils.canonicalize(path_utils.join(current.path, 'duplicate')),
      );

      final second = await const ImportComic().restoreLocalDownloads(
        legacy,
        showUi: false,
      );
      expect(second.success, isTrue, reason: second.errorMessage);
      expect(second.data.imported, 0);
      expect(second.data.conflicts, isEmpty);
      expect(manager.getComics(LocalSortType.timeDesc), hasLength(2));
    } finally {
      manager.close();
      await temp.delete(recursive: true);
    }
  });

  test(
    'keeps entries that only exist under the previous root readable',
    () async {
      final temp = await Directory.systemTemp.createTemp('venera-restore-');
      final current = Directory(path_utils.join(temp.path, 'current'))
        ..createSync(recursive: true);
      final legacy = Directory(path_utils.join(temp.path, 'legacy'))
        ..createSync(recursive: true);
      App.dataPath = temp.path;
      File(
        path_utils.join(temp.path, 'local_path'),
      ).writeAsStringSync(current.path);

      final manager = LocalManager();
      manager.close();
      await manager.init();
      _createComic(current, 'only-current');
      await manager.add(
        LocalComic(
          id: '1',
          title: 'Only Current',
          subtitle: '',
          tags: const [],
          directory: 'only-current',
          chapters: null,
          cover: '1.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      _createComic(legacy, 'new-comic', title: 'New Comic');

      try {
        final result = await const ImportComic().restoreLocalDownloads(
          legacy,
          showUi: false,
        );
        expect(result.success, isTrue, reason: result.errorMessage);

        final kept = manager.find('1', ComicType.local);
        expect(kept, isNotNull);
        expect(
          path_utils.canonicalize(kept!.directory),
          path_utils.canonicalize(
            path_utils.join(current.path, 'only-current'),
          ),
        );
        expect(kept.managedByApp, isFalse);
        expect(
          File(path_utils.join(kept.baseDir, '1.jpg')).existsSync(),
          isTrue,
        );
      } finally {
        manager.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('deletes or renames only the old duplicate copy', () async {
    final temp = await Directory.systemTemp.createTemp('venera-restore-');
    final current = Directory(path_utils.join(temp.path, 'current'))
      ..createSync(recursive: true);
    final legacy = Directory(path_utils.join(temp.path, 'legacy'))
      ..createSync(recursive: true);
    App.dataPath = temp.path;
    File(
      path_utils.join(temp.path, 'local_path'),
    ).writeAsStringSync(current.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    _createComic(current, 'duplicate');
    await manager.add(
      LocalComic(
        id: '1',
        title: 'Duplicate',
        subtitle: '',
        tags: const [],
        directory: 'duplicate',
        chapters: null,
        cover: '1.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    _createComic(legacy, 'duplicate');

    try {
      final result = await const ImportComic().restoreLocalDownloads(
        legacy,
        showUi: false,
      );
      expect(result.success, isTrue, reason: result.errorMessage);
      final data = result.data;
      expect(data.conflicts, hasLength(1));
      final conflict = data.conflicts.single;
      final active = Directory(conflict.activePath);
      final duplicate = Directory(conflict.duplicatePath);
      expect(active.existsSync(), isTrue);
      expect(duplicate.existsSync(), isTrue);

      final deleteError = await manager.deleteLegacyDuplicate(
        conflict.duplicatePath,
        data.previousRoot,
      );
      expect(deleteError, isNull);
      expect(duplicate.existsSync(), isFalse);
      expect(active.existsSync(), isTrue);
      expect(manager.find('1', ComicType.local), isNotNull);
    } finally {
      manager.close();
      await temp.delete(recursive: true);
    }
  });

  test('renames the old duplicate copy when keeping it', () async {
    final temp = await Directory.systemTemp.createTemp('venera-restore-');
    final current = Directory(path_utils.join(temp.path, 'current'))
      ..createSync(recursive: true);
    final legacy = Directory(path_utils.join(temp.path, 'legacy'))
      ..createSync(recursive: true);
    App.dataPath = temp.path;
    File(
      path_utils.join(temp.path, 'local_path'),
    ).writeAsStringSync(current.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    _createComic(current, 'duplicate');
    await manager.add(
      LocalComic(
        id: '1',
        title: 'Duplicate',
        subtitle: '',
        tags: const [],
        directory: 'duplicate',
        chapters: null,
        cover: '1.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    _createComic(legacy, 'duplicate');

    try {
      final result = await const ImportComic().restoreLocalDownloads(
        legacy,
        showUi: false,
      );
      expect(result.success, isTrue, reason: result.errorMessage);
      final conflict = result.data.conflicts.single;

      final renameError = await manager.renameLegacyDuplicate(
        conflict.duplicatePath,
        result.data.previousRoot,
      );
      expect(renameError, isNull);
      expect(Directory(conflict.duplicatePath).existsSync(), isFalse);
      expect(Directory(conflict.activePath).existsSync(), isTrue);
      final renamed = current
          .listSync()
          .whereType<Directory>()
          .where(
            (directory) => path_utils
                .basename(directory.path)
                .startsWith('duplicate (old copy)'),
          )
          .toList();
      expect(renamed, hasLength(1));
    } finally {
      manager.close();
      await temp.delete(recursive: true);
    }
  });

  test('rejects nested storage paths', () async {
    final temp = await Directory.systemTemp.createTemp('venera-restore-');
    final current = Directory(path_utils.join(temp.path, 'current'))
      ..createSync(recursive: true);
    final nested = Directory(path_utils.join(current.path, 'nested'))
      ..createSync(recursive: true);
    App.dataPath = temp.path;
    File(
      path_utils.join(temp.path, 'local_path'),
    ).writeAsStringSync(current.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    try {
      final result = await manager.adoptExistingPath(nested.path);
      expect(result.success, isFalse);
      expect(result.errorMessage, isNotNull);
      expect(manager.path, current.path);
    } finally {
      manager.close();
      await temp.delete(recursive: true);
    }
  });

  test('refuses to delete a directory still referenced by the library', () async {
    final temp = await Directory.systemTemp.createTemp('venera-restore-');
    final current = Directory(path_utils.join(temp.path, 'current'))
      ..createSync(recursive: true);
    App.dataPath = temp.path;
    File(
      path_utils.join(temp.path, 'local_path'),
    ).writeAsStringSync(current.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    _createComic(current, 'kept');
    await manager.add(
      LocalComic(
        id: '1',
        title: 'Kept',
        subtitle: '',
        tags: const [],
        directory: 'kept',
        chapters: null,
        cover: '1.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );

    try {
      final error = await manager.deleteLegacyDuplicate(
        path_utils.join(current.path, 'kept'),
        current.path,
      );
      expect(error, isNotNull);
      expect(Directory(path_utils.join(current.path, 'kept')).existsSync(), isTrue);

      final outside = await manager.deleteLegacyDuplicate(
        path_utils.join(temp.path, 'outside'),
        current.path,
      );
      expect(outside, isNotNull);
    } finally {
      manager.close();
      await temp.delete(recursive: true);
    }
  });

  test('deleting a restored comic follows normal local deletion', () async {
    final temp = await Directory.systemTemp.createTemp('venera-restore-');
    final current = Directory(path_utils.join(temp.path, 'current'))
      ..createSync(recursive: true);
    final legacy = Directory(path_utils.join(temp.path, 'legacy'))
      ..createSync(recursive: true);
    App.dataPath = temp.path;
    File(
      path_utils.join(temp.path, 'local_path'),
    ).writeAsStringSync(current.path);

    final manager = LocalManager();
    manager.close();
    await manager.init();
    _createComic(legacy, 'new-comic', title: 'New Comic');

    try {
      final result = await const ImportComic().restoreLocalDownloads(
        legacy,
        showUi: false,
      );
      expect(result.success, isTrue, reason: result.errorMessage);
      final comic = manager.findByName('New Comic');
      expect(comic, isNotNull);
      expect(comic!.managedByApp, isTrue);

      manager.batchDeleteComics([comic], true, false);
      final directory = Directory(path_utils.join(legacy.path, 'new-comic'));
      for (var attempt = 0; attempt < 50 && directory.existsSync(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(directory.existsSync(), isFalse);
      expect(manager.findByName('New Comic'), isNull);
    } finally {
      manager.close();
      await temp.delete(recursive: true);
    }
  });
}

void _createComic(Directory root, String name, {int pages = 1, String? title}) {
  final directory = Directory(path_utils.join(root.path, name))
    ..createSync(recursive: true);
  for (var i = 1; i <= pages; i++) {
    File(path_utils.join(directory.path, '$i.jpg')).writeAsBytesSync(const [1]);
  }
  if (title != null) {
    File(
      path_utils.join(directory.path, 'metadata.json'),
    ).writeAsStringSync(jsonEncode({'title': title}));
  }
}
