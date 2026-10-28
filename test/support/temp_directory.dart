import 'dart:io';

/// Deletes a test-owned temporary directory.
///
/// Windows refuses to delete a directory while a file inside it is still open.
/// Some tests intentionally leave background work running, so give that work a
/// short window to release its handles before reporting a real failure.
///
/// The Flutter image pipeline can keep recently loaded image files open until
/// the test process exits. In that case the remaining directory is left in the
/// system temp folder (and reported) instead of failing an otherwise green
/// test on Windows.
Future<void> deleteTempDirectory(Directory directory) async {
  const attempts = 50;
  for (var attempt = 0; ; attempt++) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (!Platform.isWindows) rethrow;
      if (attempt < attempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      final locked = await _lockedPaths(directory);
      stderr.writeln(
        'Warning: could not delete ${directory.path}'
        '${locked.isEmpty ? '' : '; still open: ${locked.join(', ')}'}',
      );
      return;
    }
  }
}

Future<List<String>> _lockedPaths(Directory directory) async {
  final locked = <String>[];
  if (!await directory.exists()) return locked;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      try {
        await entity.delete();
      } on FileSystemException {
        locked.add(entity.path);
      }
    }
  }
  return locked;
}
