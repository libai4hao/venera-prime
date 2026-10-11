import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/utils/translations.dart';

class _HistoryManager with ChangeNotifier implements HistoryManager {
  final records = <History>[];
  int finds = 0;
  int allReads = 0;
  int batches = 0;
  int singleDeletes = 0;

  @override
  List<History> getAll() {
    allReads++;
    return List.of(records);
  }

  @override
  History? find(String id, ComicType type) {
    finds++;
    return null;
  }

  @override
  void remove(String id, ComicType type) {
    singleDeletes++;
    records.removeWhere((h) => h.id == id && h.type == type);
    notifyListeners();
  }

  @override
  void batchDeleteHistories(List<ComicID> histories) {
    batches++;
    for (final id in histories) {
      records.removeWhere((h) => h.id == id.id && h.type == id.type);
    }
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FavoritesManager with ChangeNotifier implements LocalFavoritesManager {
  final comics = List.generate(
    400,
    (i) => FavoriteItem(
      id: '$i',
      name: 'blocked-fixture $i',
      coverPath: '',
      author: '',
      type: const ComicType(123),
      tags: const [],
    ),
  );

  @override
  List<String> get folderNames => ['Test'];
  @override
  int get totalComics => comics.length;
  @override
  bool existsFolder(String name) => name == 'Test';
  @override
  int folderComics(String name) => comics.length;
  @override
  List<FavoriteItem> getFolderComics(String name) => comics;
  @override
  (String?, String?) findLinked(String name) => (null, null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  late _HistoryManager history;
  setUp(() {
    final previousHistory = HistoryManager.cache;
    final previousFavorites = LocalFavoritesManager.cache;
    final previousBlocked = appdata.settings['blockedWords'];
    final previousFolder = appdata.implicitData['favoriteFolder'];
    final previousFilter = appdata.implicitData['local_favorites_read_filter'];
    history = _HistoryManager();
    HistoryManager.cache = history;
    LocalFavoritesManager.cache = _FavoritesManager();
    // Keep the test focused on list work, independent of image loading.
    appdata.settings['blockedWords'] = ['blocked-fixture'];
    appdata.implicitData['favoriteFolder'] = {
      'name': 'Test',
      'isNetwork': false,
    };
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    addTearDown(() {
      HistoryManager.cache = previousHistory;
      LocalFavoritesManager.cache = previousFavorites;
      appdata.settings['blockedWords'] = previousBlocked;
      appdata.implicitData['favoriteFolder'] = previousFolder;
      appdata.implicitData['local_favorites_read_filter'] = previousFilter;
    });
  });

  testWidgets('All favorites does not look up history for the whole folder', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FavoritesPage())),
    );
    await tester.pumpAndSettle();
    expect(history.finds, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history multi-delete refreshes the list once for the batch', (
    tester,
  ) async {
    history.records.addAll(
      List.generate(
        300,
        (i) => History.fromMap({
          'id': '$i',
          'type': i.isEven ? 0 : 123,
          'title': 'blocked-fixture $i',
          'subtitle': '',
          'cover': '',
          'time': 0,
          'ep': 1,
          'page': 1,
        }),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pump();
    final readsBeforeDelete = history.allReads;
    await tester.tap(find.byIcon(Icons.delete));
    await tester.pumpAndSettle();
    expect(history.records, isEmpty);
    expect(history.batches, 1);
    expect(history.singleDeletes, 0);
    expect(history.allReads - readsBeforeDelete, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
