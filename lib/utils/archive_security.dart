import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive_pkg;
import 'package:path/path.dart' as path_utils;
import 'package:flutter_7zip/flutter_7zip.dart' as seven_zip;
import 'package:zip_flutter/zip_flutter.dart' deferred as zip_flutter;

/// Bounded archive extraction used for untrusted downloads and imports.
///
/// Extraction always happens into a staging directory. Callers should only
/// publish that directory after their own validation succeeds.
class _ArchiveLimitException extends FormatException {
  const _ArchiveLimitException(super.message);
}

class _BoundedOutputStream extends archive_pkg.OutputStream {
  final archive_pkg.OutputStream _output;
  final int _maxBytes;
  archive_pkg.Crc32 _crc = archive_pkg.Crc32();
  int _bytesWritten = 0;

  _BoundedOutputStream(this._output, this._maxBytes)
    : super(byteOrder: _output.byteOrder);

  int get crc32 => _crc.hash;

  @override
  bool get isOpen => _output.isOpen;

  @override
  int get length => _bytesWritten;

  @override
  void flush() => _output.flush();

  @override
  Future<void> close() async {
    await _output.close();
  }

  @override
  void closeSync() => _output.closeSync();

  @override
  void clear() {
    _output.clear();
    _bytesWritten = 0;
    _crc = archive_pkg.Crc32();
  }

  void _checkWrite(int count) {
    if (count < 0 || _bytesWritten + count > _maxBytes) {
      throw const _ArchiveLimitException(
        'Archive entry expands beyond its declared size',
      );
    }
  }

  @override
  void writeByte(int value) {
    _checkWrite(1);
    _output.writeByte(value);
    _crc.add([value]);
    _bytesWritten++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw const FormatException('Archive entry produced an invalid write');
    }
    _checkWrite(count);
    _output.writeBytes(bytes, length: count);
    if (count > 0) {
      _crc.add(count == bytes.length ? bytes : bytes.sublist(0, count));
    }
    _bytesWritten += count;
  }

  @override
  void writeStream(archive_pkg.InputStream stream) {
    const chunkSize = 64 * 1024;
    while (!stream.isEOS) {
      final count = stream.length < chunkSize ? stream.length : chunkSize;
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}

abstract final class ArchiveSecurity {
  static const maxEntries = 20000;
  static const maxSingleFileBytes = 256 * 1024 * 1024;
  static const maxTotalBytes = 1024 * 1024 * 1024;
  static const maxCompressionRatio = 1000;
  static const maxArchiveBytes = 2 * 1024 * 1024 * 1024;

  static String safeTarget(String root, String archiveName) {
    final normalized = archiveName.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.contains('\u0000')) {
      throw const FormatException('Archive contains an invalid entry name');
    }
    if (normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw const FormatException('Archive contains an absolute entry path');
    }
    final segments = normalized.split('/');
    if (segments.any((segment) => segment == '..')) {
      throw const FormatException('Archive contains a parent entry path');
    }
    final canonicalRoot = path_utils.canonicalize(root);
    final target = path_utils.canonicalize(
      path_utils.join(canonicalRoot, normalized),
    );
    if (target != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, target)) {
      throw const FormatException('Archive entry escapes extraction directory');
    }
    return target;
  }

  static void _checkLimits({
    required int entries,
    required int totalBytes,
    required int archiveBytes,
  }) {
    if (entries > maxEntries) {
      throw const FormatException('Archive contains too many entries');
    }
    if (totalBytes > maxTotalBytes) {
      throw const FormatException('Archive expands beyond the allowed size');
    }
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    if (archiveBytes > 0 && totalBytes > archiveBytes * maxCompressionRatio) {
      throw const FormatException('Archive compression ratio is unsafe');
    }
  }

  static Future<int> _fileCrc32(File file) async {
    final crc = archive_pkg.Crc32();
    await for (final chunk in file.openRead()) {
      crc.add(chunk);
    }
    return crc.hash;
  }

  static void _checkExistingPath(String root, String target) {
    var current = target;
    final canonicalRoot = path_utils.canonicalize(root);
    while (true) {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException('Archive extraction encountered a symlink');
      }
      if (current == canonicalRoot) break;
      final parent = path_utils.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }

  static Future<void> extractZip(File input, Directory output) async {
    final archiveBytes = await input.length();
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    final stream = archive_pkg.InputFileStream(input.path);
    try {
      final directory = archive_pkg.ZipDirectory()..read(stream);
      final root = path_utils.canonicalize(output.path);
      final seen = <String>{};
      dynamic nativeArchive;
      final verifiedSizes = <String, int>{};
      final verifiedCrcs = <String, int>{};
      // Native Venera 1.6 ZIPs have correct central-directory sizes, while
      // archive's lazy entry objects can report zero on every platform.
      // Preflight the directory before decoding content (including symlinks).
      var total = 0;
      for (final entry in directory.fileHeaders) {
        final target = safeTarget(root, entry.filename);
        if (!seen.add(target)) {
          throw const FormatException('Archive contains duplicate entry names');
        }
        if (((entry.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
          throw const FormatException('Archive symlinks are not supported');
        }
        final size = entry.uncompressedSize;
        if (size < 0 || size > maxSingleFileBytes) {
          throw const FormatException('Archive entry is too large');
        }
        verifiedSizes[entry.filename] = size;
        verifiedCrcs[entry.filename] = entry.crc32;
        total += size;
      }
      _checkLimits(
        entries: directory.fileHeaders.length,
        totalBytes: total,
        archiveBytes: archiveBytes,
      );
      stream.position = 0;
      final archive = archive_pkg.ZipDecoder().decodeStream(stream);
      await output.create(recursive: true);
      var actualTotal = 0;
      try {
        for (var index = 0; index < archive.length; index++) {
          final entry = archive[index];
          if (!verifiedSizes.containsKey(entry.name)) {
            throw const FormatException(
              'Archive local and central entry names differ',
            );
          }
          final target = safeTarget(root, entry.name);
          _checkExistingPath(root, target);
          if (entry.isSymbolicLink) {
            throw const FormatException('Archive symlinks are not supported');
          }
          if (entry.isDirectory) {
            await Directory(target).create(recursive: true);
            continue;
          }
          final expectedSize = verifiedSizes[entry.name] ?? entry.size;
          final expectedCrc = verifiedCrcs[entry.name] ?? entry.crc32 ?? 0;
          final targetFile = File(target);
          await targetFile.parent.create(recursive: true);
          var extractedByNative = false;
          try {
            final outputStream = _BoundedOutputStream(
              archive_pkg.OutputFileStream(target),
              expectedSize,
            );
            try {
              entry.writeContent(outputStream);
            } finally {
              outputStream.closeSync();
            }
            if (outputStream.length != expectedSize) {
              throw FormatException(
                'Archive entry size mismatch: expected $expectedSize',
              );
            }
            if (outputStream.crc32 != expectedCrc) {
              throw const FormatException('Archive entry checksum mismatch');
            }
          } catch (error) {
            if (error is _ArchiveLimitException) {
              if (await targetFile.exists()) await targetFile.delete();
              rethrow;
            }
            if (await targetFile.exists()) await targetFile.delete();
            await zip_flutter.loadLibrary();
            nativeArchive ??= zip_flutter.ZipFile.openRead(input.path);
            // The native fallback reads into a buffer bounded by the verified
            // central-directory size instead of streaming an unchecked file.
            final nativeEntry = nativeArchive.getEntryByName(entry.name);
            if (nativeEntry.size != expectedSize) {
              throw const FormatException(
                'Archive entry size mismatch before native extraction',
              );
            }
            final content = nativeEntry.read();
            if (content.length != expectedSize) {
              throw const FormatException(
                'Archive entry size mismatch after native extraction',
              );
            }
            if (archive_pkg.getCrc32(content) != expectedCrc) {
              throw const FormatException(
                'Archive entry checksum mismatch after native extraction',
              );
            }
            await targetFile.writeAsBytes(content, flush: true);
            extractedByNative = true;
          }
          if (extractedByNative) {
            actualTotal += expectedSize;
            _checkLimits(
              entries: index + 1,
              totalBytes: actualTotal,
              archiveBytes: archiveBytes,
            );
            continue;
          }
          final actualLength = await targetFile.length();
          if (actualLength != expectedSize) {
            throw FormatException(
              'Archive entry size mismatch: expected $expectedSize, got $actualLength',
            );
          }
          actualTotal += actualLength;
          _checkLimits(
            entries: index + 1,
            totalBytes: actualTotal,
            archiveBytes: archiveBytes,
          );
        }
      } finally {
        nativeArchive?.close();
      }
    } finally {
      await stream.close();
    }
  }

  static Future<void> extract7z(File input, Directory output) async {
    final seven_zip.SZArchive archive;
    try {
      archive = seven_zip.SZArchive.open(input.path);
    } catch (error) {
      throw FormatException('Failed to open 7z archive: $error');
    }
    try {
      final root = path_utils.canonicalize(output.path);
      final seen = <String>{};
      var total = 0;
      for (var i = 0; i < archive.numFiles; i++) {
        final entry = archive.getFile(i);
        final target = safeTarget(root, entry.name);
        if (!seen.add(target)) {
          throw const FormatException('Archive contains duplicate entry names');
        }
        if (!entry.isDirectory) {
          if (entry.size > maxSingleFileBytes) {
            throw const FormatException('Archive entry is too large');
          }
          total += entry.size;
        }
      }
      final archiveBytes = await input.length();
      _checkLimits(
        entries: archive.numFiles,
        totalBytes: total,
        archiveBytes: archiveBytes,
      );
      await output.create(recursive: true);
      var actualTotal = 0;
      for (var i = 0; i < archive.numFiles; i++) {
        final entry = archive.getFile(i);
        final target = safeTarget(root, entry.name);
        _checkExistingPath(root, target);
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await Directory(path_utils.dirname(target)).create(recursive: true);
        final targetFile = File(target);
        try {
          archive.extractToFile(i, target);
          if (FileSystemEntity.typeSync(target, followLinks: false) ==
              FileSystemEntityType.link) {
            throw const FormatException('Archive symlinks are not supported');
          }
          final actualLength = await targetFile.length();
          if (actualLength != entry.size) {
            throw const FormatException('Archive entry size mismatch');
          }
          if (entry.crc32 != 0 && await _fileCrc32(targetFile) != entry.crc32) {
            throw const FormatException('Archive entry checksum mismatch');
          }
        } catch (error) {
          if (await targetFile.exists()) await targetFile.delete();
          if (error is FormatException) rethrow;
          throw FormatException('Failed to extract 7z entry: $error');
        }
        actualTotal += entry.size;
        _checkLimits(
          entries: i + 1,
          totalBytes: actualTotal,
          archiveBytes: archiveBytes,
        );
      }
    } finally {
      archive.dispose();
    }
  }

  static Future<void> extract(File input, Directory output) async {
    final header = await input
        .openRead(0, 32)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final name = input.path.toLowerCase();
    if (header.length >= 2 && header[0] == 0x50 && header[1] == 0x4b) {
      await extractZip(input, output);
    } else if (name.endsWith('.7z') ||
        (header.length >= 6 &&
            header[0] == 0x37 &&
            header[1] == 0x7a &&
            header[2] == 0xbc &&
            header[3] == 0xaf &&
            header[4] == 0x27 &&
            header[5] == 0x1c)) {
      await extract7z(input, output);
    } else {
      throw const FormatException('Unsupported archive type');
    }
  }
}
