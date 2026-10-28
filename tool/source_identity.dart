import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Source identity is persisted as `key.hashCode` of the source script key
/// everywhere in the databases (see lib/foundation/comic_type.dart). When the
/// installed scripts or the Dart runtime change, those ints no longer match a
/// source and comics lose their origin. This tool recovers and verifies them.
///
/// Usage:
///   dart run tool/source_identity.dart verify --data <app data path>
///   dart run tool/source_identity.dart recover --data <app data path> [--apply]
///       [--key k1,k2] [--map 12345=alpha]
///
/// `recover` is a dry run unless `--apply` is given.
const localComicType = 0;

const _downloadInfoFileName = '.venera_download.json';
const _backupDirPrefix = 'identity_backup_';
const _sourceKeyPattern = r'''key\s*=\s*["']([^"']+)["']''';

class SourceIdentityChange {
  const SourceIdentityChange({
    required this.database,
    required this.table,
    required this.id,
    required this.from,
    required this.to,
    required this.sourceKey,
    required this.witness,
  });

  final String database;
  final String table;
  final String id;
  final int from;
  final int to;
  final String sourceKey;
  final String witness;

  @override
  String toString() =>
      '$database | $table | $id | $from -> $to | $sourceKey ($witness)';
}

class SourceIdentityReport {
  SourceIdentityReport({
    required this.applied,
    required this.backupPath,
    required this.changes,
    required this.unresolved,
    required this.keys,
  });

  final bool applied;
  final String? backupPath;
  final List<SourceIdentityChange> changes;
  final List<String> unresolved;
  final List<String> keys;

  bool get clean => changes.isEmpty && unresolved.isEmpty;
}

/// Read only check. Returns one line per source value that matches no installed
/// source, plus database integrity problems.
List<String> verifySourceIdentity(
  String dataPath, {
  List<String> keys = const [],
  Map<int, String> manual = const {},
}) {
  final installed = _installedKeys(dataPath, keys);
  final scan = _scan(dataPath);
  final issues = <String>[];

  bool matches(int value) =>
      value == localComicType ||
      installed.any((key) => key.hashCode == value);

  for (final row in scan.rows) {
    if (!matches(row.value)) {
      issues.add(
        '${row.database}/${row.table}/${row.id}: ${row.column} ${row.value} '
        'matches no installed source',
      );
    }
  }
  for (final marker in scan.markers) {
    if (!matches(marker.value)) {
      issues.add(
        '${marker.directory}/$_downloadInfoFileName: type ${marker.value} '
        'matches no installed source',
      );
    }
  }
  for (final database in scan.databases) {
    final db = sqlite3.open(database);
    try {
      for (final row in db.select('PRAGMA integrity_check;')) {
        final result = row.values.first;
        if (result != 'ok') {
          issues.add('$database: integrity_check $result');
        }
      }
    } finally {
      db.dispose();
    }
  }
  return issues;
}

/// Rewrites source ints that can be traced back to a key. With [apply] false it
/// only reports what it would change.
SourceIdentityReport recoverSourceIdentity(
  String dataPath, {
  List<String> keys = const [],
  Map<int, String> manual = const {},
  bool apply = false,
}) {
  final installed = _installedKeys(dataPath, keys);
  final effectiveManual = {
    // The local library is not a source and is never rewritten.
    localComicType: null,
    ...manual,
  }..remove(localComicType);
  final scan = _scan(dataPath);
  final changes = <SourceIdentityChange>[];
  final unresolved = <String>[];
  final pending = <_PendingUpdate>[];

  String? resolve(int value, String id) {
    if (value == localComicType) {
      return null;
    }
    final byId = scan.idKeys[id];
    if (byId != null) {
      return byId;
    }
    final byValue = scan.intKeys[value];
    if (byValue != null) {
      return byValue;
    }
    return effectiveManual[value];
  }

  String witnessFor(int value, String id) {
    if (scan.idKeys[id] != null) {
      return 'comic id';
    }
    if (scan.intKeys[value] != null) {
      return 'comic_type';
    }
    return 'manual';
  }

  for (final row in scan.rows) {
    if (row.value == localComicType) {
      continue;
    }
    final key = resolve(row.value, row.id);
    if (key == null) {
      unresolved.add(
        '${row.database}/${row.table}/${row.id}: ${row.column} ${row.value}',
      );
      continue;
    }
    final next = key.hashCode;
    if (next == row.value) {
      continue;
    }
    changes.add(
      SourceIdentityChange(
        database: row.database,
        table: row.table,
        id: row.id,
        from: row.value,
        to: next,
        sourceKey: key,
        witness: witnessFor(row.value, row.id),
      ),
    );
    pending.add(_PendingUpdate(row, next));
  }

  final markerChanges = <_MarkerChange>[];
  for (final marker in scan.markers) {
    if (marker.value == localComicType) {
      continue;
    }
    final key = resolve(marker.value, marker.id);
    if (key == null) {
      unresolved.add('${marker.directory}/$_downloadInfoFileName: ${marker.value}');
      continue;
    }
    final next = key.hashCode;
    if (next == marker.value) {
      continue;
    }
    markerChanges.add(_MarkerChange(marker, next));
  }

  final report = SourceIdentityReport(
    applied: apply,
    backupPath: null,
    changes: changes,
    unresolved: unresolved,
    keys: installed,
  );
  if (!apply) {
    return report;
  }

  final files = <String>{
    for (final update in pending) update.row.database,
    for (final change in markerChanges) change.marker.file.path,
  };
  final backupPath = _backup(dataPath, files);
  for (final entry in _groupByDatabase(pending).entries) {
    _applyDatabase(entry.key, entry.value);
  }
  for (final change in markerChanges) {
    _writeMarker(change.marker, change.value);
  }
  return SourceIdentityReport(
    applied: true,
    backupPath: backupPath,
    changes: changes,
    unresolved: unresolved,
    keys: installed,
  );
}

void main(List<String> args) {
  final command = args.isEmpty ? 'verify' : args.first;
  if (!const ['verify', 'recover'].contains(command)) {
    stderr.writeln('Usage: source_identity.dart verify|recover --data <path> '
        '[--apply] [--key k1,k2] [--map 12345=key]');
    exit(64);
  }
  final dataPath = _flag(args, '--data');
  if (dataPath == null || !Directory(dataPath).existsSync()) {
    stderr.writeln('--data <app data path> is required and must exist');
    exit(64);
  }
  final keys = _flag(args, '--key')
          ?.split(',')
          .map((key) => key.trim())
          .where((key) => key.isNotEmpty)
          .toList() ??
      const <String>[];
  final manual = <int, String>{};
  for (final pair in _flag(args, '--map')?.split(',') ?? const <String>[]) {
    final index = pair.indexOf('=');
    if (index <= 0) continue;
    final value = int.tryParse(pair.substring(0, index).trim());
    final key = pair.substring(index + 1).trim();
    if (value == null || key.isEmpty) continue;
    manual[value] = key;
  }

  if (command == 'verify') {
    final issues = verifySourceIdentity(dataPath, keys: keys, manual: manual);
    for (final issue in issues) {
      stdout.writeln(issue);
    }
    stdout.writeln(issues.isEmpty ? 'Source identities look consistent.' : '${issues.length} problem(s) found.');
    exit(issues.isEmpty ? 0 : 1);
  }

  final apply = args.contains('--apply');
  final report =
      recoverSourceIdentity(dataPath, keys: keys, manual: manual, apply: apply);
  stdout.writeln('Installed sources: ${report.keys.join(', ')}');
  if (report.changes.isEmpty) {
    stdout.writeln('No recoverable source identity found.');
  }
  for (final change in report.changes) {
    stdout.writeln(apply ? 'fixed   $change' : 'would fix $change');
  }
  for (final entry in report.unresolved) {
    stdout.writeln('manual  $entry');
  }
  if (apply) {
    stdout.writeln('Backup: ${report.backupPath}');
    stdout.writeln('Restart the app so the new identities are loaded.');
  } else if (report.changes.isNotEmpty) {
    stdout.writeln('Dry run. Re-run with --apply to write the changes.');
  }
  exit(report.unresolved.isEmpty ? 0 : 1);
}

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

List<String> _installedKeys(String dataPath, List<String> extra) {
  final keys = <String>{...extra.where((key) => key.isNotEmpty)};
  final directory = Directory('$dataPath/comic_source');
  if (directory.existsSync()) {
    final pattern = RegExp(_sourceKeyPattern);
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.js')) {
        continue;
      }
      try {
        final match = pattern.firstMatch(entity.readAsStringSync());
        final key = match?.group(1);
        if (key != null && key.isNotEmpty) {
          keys.add(key);
        }
      } catch (_) {
        // A broken script simply contributes no key.
      }
    }
  }
  return keys.toList()..sort();
}

class _SourceRow {
  _SourceRow(this.database, this.table, this.column, this.id, this.value);

  final String database;
  final String table;
  final String column;
  final String id;
  final int value;
}

class _Marker {
  _Marker(this.file, this.directory, this.id, this.value);

  final File file;
  final String directory;
  final String id;
  final int value;

  Map<String, dynamic> get json =>
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

class _ScanResult {
  _ScanResult(this.databases, this.rows, this.markers, this.idKeys, this.intKeys);

  final List<String> databases;
  final List<_SourceRow> rows;
  final List<_Marker> markers;
  final Map<String, String> idKeys;
  final Map<int, String> intKeys;
}

class _PendingUpdate {
  _PendingUpdate(this.row, this.value);

  final _SourceRow row;
  final int value;
}

class _MarkerChange {
  _MarkerChange(this.marker, this.value);

  final _Marker marker;
  final int value;
}

/// Databases that carry a source int, with the table and identity column.
const _sourceTables = <String, Map<String, String>>{
  'history.db': {'history': 'type'},
  'local.db': {'comics': 'comic_type'},
  'read_later.db': {'read_later': 'comic_type'},
  'reading_statistics.db': {'reading_statistics': 'comic_type'},
};

const _favoritesDatabase = 'local_favorite.db';
const _favoritesSkippedTables = {'folder_order', 'folder_sync'};
const _nonComicIdColumn = {'reading_statistics': 'comic_id'};

_ScanResult _scan(String dataPath) {
  final databases = <String>[];
  final rows = <_SourceRow>[];
  final markers = <_Marker>[];
  final idKeys = <String, String>{};
  final intKeys = <int, String>{};
  final ambiguousIds = <String>{};

  void rememberId(String id, String key) {
    if (id.isEmpty || ambiguousIds.contains(id)) {
      return;
    }
    final existing = idKeys[id];
    if (existing == null) {
      idKeys[id] = key;
    } else if (existing != key) {
      ambiguousIds.add(id);
      idKeys.remove(id);
    }
  }

  for (final entry in _sourceTables.entries) {
    final path = '$dataPath/${entry.key}';
    if (!File(path).existsSync()) {
      continue;
    }
    final db = sqlite3.open(path);
    try {
      for (final table in entry.value.entries) {
        if (!_hasTable(db, table.key)) {
          continue;
        }
        final idColumn = _nonComicIdColumn[table.key] ?? 'id';
        databases.add(path);
        for (final row in db.select(
          'SELECT "$idColumn", "${table.value}" FROM "${table.key}";',
        )) {
          final id = row[0]?.toString() ?? '';
          final value = row[1];
          if (value is! int) {
            continue;
          }
          rows.add(_SourceRow(path, table.key, table.value, id, value));
        }
        if (table.key == 'read_later' && _hasTable(db, 'read_later')) {
          for (final row in db.select(
            'SELECT id, comic_type, source_key FROM read_later;',
          )) {
            final id = row[0]?.toString() ?? '';
            final value = row[1];
            final key = row[2]?.toString() ?? '';
            if (value is int && key.isNotEmpty) {
              intKeys[value] = key;
              rememberId(id, key);
            }
          }
        }
        if (table.key == 'history' && _hasTable(db, 'image_favorites')) {
          for (final row in db.select(
            'SELECT id, source_key FROM image_favorites;',
          )) {
            final id = row[0]?.toString() ?? '';
            final key = row[1]?.toString() ?? '';
            if (key.isNotEmpty) {
              rememberId(id, key);
            }
          }
        }
      }
    } finally {
      db.dispose();
    }
  }

  final favoritesPath = '$dataPath/$_favoritesDatabase';
  if (File(favoritesPath).existsSync()) {
    final db = sqlite3.open(favoritesPath);
    try {
      databases.add(favoritesPath);
      for (final table in _tableNames(db)) {
        if (_favoritesSkippedTables.contains(table)) {
          continue;
        }
        final columns = _columnNames(db, table);
        if (!columns.contains('id') || !columns.contains('type')) {
          continue;
        }
        for (final row in db.select('SELECT "id", "type" FROM "$table";')) {
          final id = row[0]?.toString() ?? '';
          final value = row[1];
          if (value is! int) {
            continue;
          }
          rows.add(_SourceRow(favoritesPath, table, 'type', id, value));
        }
      }
    } finally {
      db.dispose();
    }
  }

  final tasks = File('$dataPath/downloading_tasks.json');
  if (tasks.existsSync()) {
    try {
      final decoded = jsonDecode(tasks.readAsStringSync());
      if (decoded is List) {
        for (final task in decoded) {
          if (task is! Map) continue;
          final id = task['comicId']?.toString() ?? '';
          final key = task['source']?.toString() ?? '';
          if (id.isNotEmpty && key.isNotEmpty) {
            rememberId(id, key);
          }
        }
      }
    } catch (_) {
      // A corrupt task file is not a reason to stop.
    }
  }

  final localRoot = _localRoot(dataPath);
  if (localRoot.existsSync()) {
    for (final entity in localRoot.listSync()) {
      if (entity is! Directory) {
        continue;
      }
      final info = File('${entity.path}/$_downloadInfoFileName');
      if (!info.existsSync()) {
        continue;
      }
      try {
        final json = jsonDecode(info.readAsStringSync()) as Map<String, dynamic>;
        final type = json['type'];
        if (type is! int) continue;
        markers.add(
          _Marker(info, entity.path, json['id']?.toString() ?? '', type),
        );
      } catch (_) {
        // Ignore unreadable markers, they are reported by integrity checks.
      }
    }
  }

  return _ScanResult(databases, rows, markers, idKeys, intKeys);
}

Directory _localRoot(String dataPath) {
  final pointer = File('$dataPath/local_path');
  if (pointer.existsSync()) {
    final path = pointer.readAsStringSync().trim();
    if (path.isNotEmpty) {
      return Directory(path);
    }
  }
  return Directory('$dataPath/local');
}

List<String> _tableNames(Database db) => db
    .select("SELECT name FROM sqlite_master WHERE type='table';")
    .map((row) => row['name'].toString())
    .toList();

List<String> _columnNames(Database db, String table) => db
    .select('PRAGMA table_info("$table");')
    .map((row) => row['name'].toString())
    .toList();

bool _hasTable(Database db, String table) =>
    _tableNames(db).any((name) => name == table);

Map<String, List<_PendingUpdate>> _groupByDatabase(
  List<_PendingUpdate> updates,
) {
  final grouped = <String, List<_PendingUpdate>>{};
  for (final update in updates) {
    grouped.putIfAbsent(update.row.database, () => []).add(update);
  }
  return grouped;
}

void _applyDatabase(String database, List<_PendingUpdate> updates) {
  final db = sqlite3.open(database);
  try {
    db.execute('BEGIN IMMEDIATE;');
    for (final update in updates) {
      final idColumn = _nonComicIdColumn[update.row.table] ?? 'id';
      db.execute(
        'UPDATE "${update.row.table}" SET "${update.row.column}" = ? '
        'WHERE "$idColumn" = ? AND "${update.row.column}" = ?;',
        [update.value, update.row.id, update.row.value],
      );
    }
    db.execute('COMMIT;');
  } catch (_) {
    db.execute('ROLLBACK;');
    rethrow;
  } finally {
    db.dispose();
  }
}

void _writeMarker(_Marker marker, int value) {
  final json = marker.json..['type'] = value;
  marker.file.writeAsStringSync(jsonEncode(json));
}

String _backup(String dataPath, Iterable<String> files) {
  final backupPath =
      '$dataPath/$_backupDirPrefix${DateTime.now().millisecondsSinceEpoch}';
  for (final file in files.toSet()) {
    final relative = file.substring(dataPath.length).replaceAll('\\', '/');
    final target = File('$backupPath$relative');
    target.parent.createSync(recursive: true);
    File(file).copySync(target.path);
  }
  return backupPath;
}
