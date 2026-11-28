import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera/utils/archive_security.dart';

const _sevenZipFixture =
    'N3q8ryccAATXb6p/BwAAAAAAAABaAAAAAAAAADnAsh8BAAJhYmMAAQQGAAEJBwAHCwEAASEhAQAMAwAICgHCQSQ1AAAFARkMAAAAAAAAAAAAAAAAERMAcABhAGcAZQAuAHQAeAB0AAAAGQAUCgEA0Zfuc2Z83QEVBgEAIAAAAAAA';

Uint8List _sevenZipWithDeclaredSize(int size) {
  final bytes = base64Decode(_sevenZipFixture);
  // The fixture stores three bytes, with its header at 39 and size at 57.
  bytes[57] = size;
  ByteData.sublistView(
    bytes,
  ).setUint32(28, getCrc32(bytes.sublist(39)), Endian.little);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native 7z extraction accepts matching declared sizes', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('valid-7z-');
    try {
      final input = File('${root.path}/valid.7z')
        ..writeAsBytesSync(_sevenZipWithDeclaredSize(3));
      final output = Directory('${root.path}/out');
      await ArchiveSecurity.extract7z(input, output);
      expect(await File('${output.path}/page.txt').readAsBytes(), [97, 98, 99]);
    } finally {
      await root.delete(recursive: true);
    }
  });

  testWidgets('native 7z extraction rejects a forged declared size', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('forged-7z-');
    try {
      final input = File('${root.path}/forged.7z')
        ..writeAsBytesSync(_sevenZipWithDeclaredSize(1));
      final output = Directory('${root.path}/out');
      await expectLater(
        ArchiveSecurity.extract7z(input, output),
        throwsA(isA<FormatException>()),
      );
      expect(File('${output.path}/page.txt').existsSync(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
