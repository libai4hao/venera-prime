import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/availability.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'support/source_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'image checks decode real pixels and reject HTML and empty responses',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      await SourceAvailabilityChecker.validateImageBytes(png);
      await expectLater(
        SourceAvailabilityChecker.validateImageBytes(
          Uint8List.fromList(utf8.encode('<html>Login required</html>')),
        ),
        throwsA(anything),
      );
      await expectLater(
        SourceAvailabilityChecker.validateImageBytes(Uint8List(0)),
        throwsStateError,
      );
    },
  );

  test('catalog failure falls back to an available catalog', () async {
    final source = sourceFixture(
      explore: [
        ExplorePageData(
          'Failed',
          ExplorePageType.multiPageComicList,
          (_) async => const Res.error('Catalog unavailable'),
          null,
          null,
          null,
        ),
        ExplorePageData(
          'Available',
          ExplorePageType.singlePageWithMultiPart,
          null,
          null,
          () async => Res([
            ExplorePagePart('Part', [comicFixture('1')], null),
          ]),
          null,
        ),
      ],
      details: (id) async => Res(detailsFixture(id)),
      pages: (_, _) async => const Res(['image']),
    );
    final result = await SourceAvailabilityChecker(
      loadImage: (_, _, _, _) async {},
    ).check(source);
    expect(result.readable, isTrue);
  });

  test(
    'a readable result requires details, chapter pages and decoded image',
    () async {
      final calls = <String>[];
      final source = sourceFixture(
        explore: [
          ExplorePageData(
            'Catalog',
            ExplorePageType.multiPageComicList,
            (_) async => Res([comicFixture('1')]),
            null,
            null,
            null,
          ),
        ],
        details: (id) async {
          calls.add('details:$id');
          return Res(detailsFixture(id));
        },
        pages: (id, ep) async {
          calls.add('pages:$id:$ep');
          return const Res(['image']);
        },
      );
      final result = await SourceAvailabilityChecker(
        loadImage: (image, source, cid, ep) async {
          calls.add('image:$image:$cid:$ep');
        },
      ).check(source);
      expect(result.readable, isTrue);
      expect(result.comic!.title, 'Sample 1');
      expect(calls, ['details:1', 'pages:1:ep', 'image:image:1:ep']);
    },
  );

  test('reachable catalog with failed image is not readable', () async {
    final source = sourceFixture(
      details: (id) async => Res(detailsFixture(id)),
      pages: (_, _) async => const Res(['image']),
    );
    final result = await SourceAvailabilityChecker(
      loadImage: (_, _, _, _) async {
        throw StateError('Invalid image data');
      },
    ).check(source, comicId: '1');
    expect(result.readable, isFalse);
    expect(result.stage, SourceCheckStage.image);
    expect(result.error, contains('Invalid image data'));
  });

  test('removed first sample falls back to another comic', () async {
    final source = sourceFixture(
      explore: [
        ExplorePageData(
          'Catalog',
          ExplorePageType.multiPageComicList,
          (_) async => Res([comicFixture('removed'), comicFixture('ok')]),
          null,
          null,
          null,
        ),
      ],
      details: (id) async => id == 'removed'
          ? const Res.error('Not found')
          : Res(detailsFixture(id)),
      pages: (_, _) async => const Res(['image']),
    );
    final result = await SourceAvailabilityChecker(
      loadImage: (_, _, _, _) async {},
    ).check(source);
    expect(result.readable, isTrue);
    expect(result.comic!.id, 'ok');
  });

  test(
    'grouped chapters and sources without chapters use correct episode',
    () async {
      for (final chapters in [
        null,
        {
          'group': {'group-ep': 'Chapter'},
        },
      ]) {
        String? loadedEpisode;
        final source = sourceFixture(
          details: (id) async => Res(detailsFixture(id, chapters: chapters)),
          pages: (_, ep) async {
            loadedEpisode = ep;
            return const Res(['image']);
          },
        );
        final result = await SourceAvailabilityChecker(
          loadImage: (_, _, _, ep) async {
            expect(ep, chapters == null ? '0' : 'group-ep');
          },
        ).check(source, comicId: 'explicit');
        expect(result.readable, isTrue);
        expect(loadedEpisode, chapters == null ? null : 'group-ep');
      }
    },
  );

  test(
    'empty pages and timed out details report the actual failing stage',
    () async {
      final empty =
          await SourceAvailabilityChecker(
            loadImage: (_, _, _, _) async {},
          ).check(
            sourceFixture(
              details: (id) async => Res(detailsFixture(id)),
              pages: (_, _) async => const Res([]),
            ),
            comicId: '1',
          );
      expect(empty.stage, SourceCheckStage.pages);
      expect(empty.readable, isFalse);
      final timed =
          await SourceAvailabilityChecker(
            timeout: const Duration(milliseconds: 10),
          ).check(
            sourceFixture(
              details: (_) => Completer<Res<ComicDetails>>().future,
              pages: (_, _) async => const Res(['image']),
            ),
            comicId: '1',
          );
      expect(timed.stage, SourceCheckStage.details);
      expect(timed.error, contains('TimeoutException'));
    },
  );

  test(
    'sources with no discoverable sample can be checked by comic ID',
    () async {
      final result = await SourceAvailabilityChecker().check(sourceFixture());
      expect(result.stage, SourceCheckStage.catalog);
      expect(result.readable, isFalse);
      expect(result.error, contains('Enter a comic ID'));
    },
  );
}
