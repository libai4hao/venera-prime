import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../tool/source_identity.dart';

/// Source identity is stored as `key.hashCode` in every database. When the
/// installed scripts or the Dart runtime change, those ints stop matching a
/// source and the comic loses its origin. These tests pin the recovery and
/// verification behaviour of tool/source_identity.dart.
void main() {
  late Directory dataPath;

  setUp(() {
    dataPath = Directory.systemTemp.createTempSync('venera-identity-');
    Directory('${dataPath.path}/comic_source').createSync();
    File('${dataPath.path}/comic_source/alpha.js').writeAsStringSync('''
class Alpha extends ComicSource {
  key = "alpha";
}
''');
  });

  tearDown(() {
    dataPath.deleteSync(recursive: true);
  });

  void createHistoryDb() {
    final db = sqlite3.open('${dataPath.path}/history.db');
    db.execute('CREATE TABLE history (id TEXT NOT NULL, type INTEGER NOT NULL, '
        'PRIMARY KEY (id, type));');
    db.execute('CREATE TABLE image_favorites (id TEXT NOT NULL, '
        'source_key TEXT NOT NULL, PRIMARY KEY (id, source_key));');
    db.execute("INSERT INTO history (id, type) VALUES ('1', 12345);");
    db.execute("INSERT INTO image_favorites (id, source_key) VALUES ('1', 'alpha');");
    db.dispose();
  }

  void createReadLaterDb() {
    final db = sqlite3.open('${dataPath.path}/read_later.db');
    db.execute('CREATE TABLE read_later (id TEXT NOT NULL, '
        'comic_type INTEGER NOT NULL, source_key TEXT NOT NULL, '
        'PRIMARY KEY (id, comic_type));');
    db.execute("INSERT INTO read_later (id, comic_type, source_key) "
        "VALUES ('1', 12345, 'alpha');");
    db.dispose();
  }

  void createLocalDb() {
    final db = sqlite3.open('${dataPath.path}/local.db');
    db.execute('CREATE TABLE comics (id TEXT NOT NULL, '
        'comic_type INTEGER NOT NULL, PRIMARY KEY (id, comic_type));');
    db.execute("INSERT INTO comics (id, comic_type) VALUES ('1', 999);");
    db.dispose();
  }

  void createFavoritesDb() {
    final db = sqlite3.open('${dataPath.path}/local_favorite.db');
    db.execute('CREATE TABLE folder_order (folder_name TEXT PRIMARY KEY, '
        'order_value INTEGER NOT NULL);');
    db.execute('CREATE TABLE folder_sync (folder_name TEXT PRIMARY KEY, '
        'source_key TEXT NOT NULL, source_folder TEXT NOT NULL);');
    db.execute('CREATE TABLE "默认" (id TEXT NOT NULL, type INTEGER NOT NULL, '
        'PRIMARY KEY (id, type));');
    db.execute('INSERT INTO "默认" (id, type) VALUES (\'1\', 12345);');
    db.dispose();
  }

  void createDownloadMarker() {
    Directory('${dataPath.path}/local/comic-1').createSync(recursive: true);
    File('${dataPath.path}/local/comic-1/.venera_download.json')
        .writeAsStringSync(jsonEncode({'id': '1', 'type': 999}));
  }

  int readInt(String database, String sql) {
    final db = sqlite3.open('${dataPath.path}/$database');
    try {
      return db.select(sql).first.values.first as int;
    } finally {
      db.dispose();
    }
  }

  int markerType() {
    final file =
        File('${dataPath.path}/local/comic-1/.venera_download.json');
    return jsonDecode(file.readAsStringSync())['type'] as int;
  }

  test('verify reports every source value without a matching source', () {
    createHistoryDb();
    createReadLaterDb();
    createLocalDb();
    createFavoritesDb();
    createDownloadMarker();

    final issues = verifySourceIdentity(dataPath.path);

    expect(issues.where((issue) => issue.contains('history.db/history')), isNotEmpty);
    expect(issues.where((issue) => issue.contains('local_favorite.db')), isNotEmpty);
    expect(issues.where((issue) => issue.contains('local.db/comics')), isNotEmpty);
    expect(issues.where((issue) => issue.contains('.venera_download.json')),
        isNotEmpty);
  });

  test('recover is a dry run unless applied', () {
    createHistoryDb();
    createReadLaterDb();
    createLocalDb();
    createFavoritesDb();
    createDownloadMarker();

    final preview = recoverSourceIdentity(dataPath.path);

    expect(preview.applied, isFalse);
    expect(
      preview.changes.map((change) => change.table),
      containsAll(['history', 'comics', '默认']),
    );
    expect(
      preview.changes.every((change) => change.to == 'alpha'.hashCode),
      isTrue,
    );
    expect(readInt('history.db', 'SELECT type FROM history;'), 12345);
    expect(readInt('local.db', 'SELECT comic_type FROM comics;'), 999);
    expect(markerType(), 999);
  });

  test('recover rewrites source ids and download markers when applied', () {
    createHistoryDb();
    createReadLaterDb();
    createLocalDb();
    createFavoritesDb();
    createDownloadMarker();

    final report = recoverSourceIdentity(dataPath.path, apply: true);

    expect(report.applied, isTrue);
    expect(report.backupPath, isNotNull);
    expect(Directory(report.backupPath!).existsSync(), isTrue);
    expect(readInt('history.db', 'SELECT type FROM history;'), 'alpha'.hashCode);
    expect(
      readInt('local.db', 'SELECT comic_type FROM comics;'),
      'alpha'.hashCode,
    );
    expect(
      readInt('local_favorite.db', 'SELECT type FROM "默认";'),
      'alpha'.hashCode,
    );
    expect(markerType(), 'alpha'.hashCode);
    expect(verifySourceIdentity(dataPath.path), isEmpty);
  });

  test('recover leaves unmatchable rows untouched and reports them', () {
    createHistoryDb();
    final db = sqlite3.open('${dataPath.path}/local.db');
    db.execute('CREATE TABLE comics (id TEXT NOT NULL, '
        'comic_type INTEGER NOT NULL, PRIMARY KEY (id, comic_type));');
    db.execute("INSERT INTO comics (id, comic_type) VALUES ('2', 999);");
    db.dispose();

    final report = recoverSourceIdentity(dataPath.path, apply: true);

    expect(report.unresolved, isNotEmpty);
    expect(readInt('local.db', 'SELECT comic_type FROM comics;'), 999);
  });

  test('the local comic type is never rewritten', () {
    createHistoryDb();
    final db = sqlite3.open('${dataPath.path}/local.db');
    db.execute('CREATE TABLE comics (id TEXT NOT NULL, '
        'comic_type INTEGER NOT NULL, PRIMARY KEY (id, comic_type));');
    db.execute("INSERT INTO comics (id, comic_type) VALUES ('1', 0);");
    db.dispose();

    recoverSourceIdentity(dataPath.path, apply: true);

    expect(readInt('local.db', 'SELECT comic_type FROM comics;'), 0);
  });
}
