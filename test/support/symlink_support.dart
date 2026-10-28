import 'dart:io';

bool? _cached;

/// Whether the current process can create symbolic links.
///
/// Windows requires Developer Mode or SeCreateSymbolicLinkPrivilege. Tests that
/// exercise symlink handling should skip rather than fail when the privilege
/// is unavailable.
bool canCreateSymlinks() => _cached ??= _probe();

bool _probe() {
  final directory = Directory.systemTemp.createTempSync('prime-symlink-');
  try {
    final target = File('${directory.path}/target')..writeAsStringSync('x');
    Link('${directory.path}/link').createSync(target.path);
    return true;
  } on FileSystemException {
    return false;
  } finally {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // The probe directory is in the system temp folder; leave it alone if a
      // platform still holds a handle to it.
    }
  }
}
