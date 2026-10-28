import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/translations.dart';

void main() {
  testWidgets('local tile shows author, source, language and counts', (
    tester,
  ) async {
    await _withLocalManager(tester, () async {
      appdata.settings['comicDisplayMode'] = 'detailed';
      appdata.settings['showFavoriteStatusOnTile'] = false;
      appdata.settings['showHistoryStatusOnTile'] = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: 160,
                child: ComicTile(
                  comic: const Comic(
                    'Local Comic',
                    'cover.jpg',
                    '1',
                    'Alice',
                    ['tag-one', 'tag-two'],
                    '',
                    'local',
                    null,
                    null,
                  ),
                  info: const ComicTileInfo(
                    author: 'Alice',
                    source: 'Example Source',
                    language: 'ja',
                    chapterCount: 12,
                    pageCount: 345,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Example Source'), findsOneWidget);
      expect(find.text('ja'), findsOneWidget);
      expect(find.textContaining('12'), findsOneWidget);
      expect(find.textContaining('345'), findsOneWidget);
      expect(find.text('tag-one'), findsOneWidget);
      expect(find.text('tag-two'), findsOneWidget);
    });
  });

  testWidgets('brief tile keeps metadata on one line without overflow', (
    tester,
  ) async {
    await _withLocalManager(tester, () async {
      appdata.settings['comicDisplayMode'] = 'brief';
      appdata.settings['showFavoriteStatusOnTile'] = false;
      appdata.settings['showHistoryStatusOnTile'] = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 200,
                child: ComicTile(
                  comic: const Comic(
                    'Local Comic',
                    'cover.jpg',
                    '1',
                    '',
                    [],
                    '',
                    'local',
                    null,
                    null,
                  ),
                  info: const ComicTileInfo(
                    author: 'A very long author name that should be ellipsized',
                    source: 'Example Source',
                    language: 'ja',
                    chapterCount: 12,
                    pageCount: 345,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('345'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('missing metadata is not rendered', (tester) async {
    await _withLocalManager(tester, () async {
      appdata.settings['comicDisplayMode'] = 'detailed';
      appdata.settings['showFavoriteStatusOnTile'] = false;
      appdata.settings['showHistoryStatusOnTile'] = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: 160,
                child: ComicTile(
                  comic: const Comic(
                    'Local Comic',
                    'cover.jpg',
                    '1',
                    '',
                    [],
                    '',
                    'local',
                    null,
                    null,
                  ),
                  info: const ComicTileInfo(pageCount: 20),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('20'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _withLocalManager(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  await AppTranslation.init();
  final snapshot = Map<String, dynamic>.from(
    jsonDecode(jsonEncode(appdata.toJson())),
  );
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('venera-local-tile-'),
  ))!;
  final localDirectory = Directory('${directory.path}/local')
    ..createSync(recursive: true);
  App.dataPath = directory.path;
  File('${directory.path}/local_path').writeAsStringSync(localDirectory.path);

  final manager = LocalManager();
  manager.close();
  await tester.runAsync(manager.init);

  try {
    await body();
  } finally {
    manager.close();
    appdata.restoreMemorySnapshot(snapshot);
    await tester.runAsync(() => directory.delete(recursive: true));
  }
}
