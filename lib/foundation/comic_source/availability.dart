import 'dart:async';
import 'dart:ui' show TargetImageSize;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/image_codec.dart';

import 'comic_source.dart';

enum SourceCheckStage { catalog, details, pages, image }

class SourceCheckResult {
  const SourceCheckResult({
    required this.stage,
    this.error,
    this.comic,
    this.episode,
    this.imageKey,
  });

  final SourceCheckStage stage;
  final String? error;
  final Comic? comic;
  final String? episode;
  final String? imageKey;
  bool get readable => stage == SourceCheckStage.image && error == null;
}

typedef SourceCheckImageLoader =
    Future<void> Function(
      String imageKey,
      String sourceKey,
      String comicId,
      String episode,
    );

/// Exercises the same source callbacks and image processing as the reader.
/// A catalog or a cover alone cannot establish that a comic is readable.
class SourceAvailabilityChecker {
  SourceAvailabilityChecker({
    SourceCheckImageLoader? loadImage,
    this.timeout = const Duration(seconds: 15),
  }) : _loadImage = loadImage ?? _checkImage;

  final SourceCheckImageLoader _loadImage;
  final Duration timeout;

  static Future<void> _checkImage(
    String key,
    String source,
    String cid,
    String eid,
  ) async {
    Uint8List? bytes;
    await for (final event in ImageDownloader.loadComicImageUnwrapped(
      key,
      source,
      cid,
      eid,
      useCache: false,
    )) {
      if (event.imageBytes != null) {
        bytes = event.imageBytes;
        break;
      }
    }
    if (bytes == null) throw StateError('Empty image response');
    await validateImageBytes(bytes);
  }

  static Future<void> validateImageBytes(Uint8List bytes) async {
    if (bytes.isEmpty) throw StateError('Empty image response');
    final codec = await decodeImageBytes(
      bytes,
      getTargetSize: (w, h) {
        return const TargetImageSize(width: 512);
      },
    );
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<List<Comic>> _catalog(ComicSource source) async {
    Object? lastError;
    for (final page in source.explorePages.take(3)) {
      try {
        final comics = await _catalogPage(page).timeout(timeout);
        if (comics.isNotEmpty) return comics;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    throw StateError('No sample comics found. Enter a comic ID to check.');
  }

  Future<List<Comic>> _catalogPage(ExplorePageData page) async {
    if (page.loadPage != null) return (await page.loadPage!(1)).data;
    if (page.loadNext != null) return (await page.loadNext!(null)).data;
    if (page.loadMultiPart != null) {
      return (await page.loadMultiPart!()).data
          .expand((part) => part.comics)
          .toList();
    }
    if (page.loadMixed != null) {
      return (await page.loadMixed!(1)).data.expand<Comic>((part) {
        if (part is ExplorePagePart) return part.comics;
        if (part is List<Comic>) return part;
        return const <Comic>[];
      }).toList();
    }
    return const [];
  }

  Future<SourceCheckResult> check(ComicSource source, {String? comicId}) async {
    var stage = SourceCheckStage.catalog;
    Comic? sample;
    String? episode;
    String? imageKey;
    try {
      final id = comicId?.trim();
      final samples = id != null && id.isNotEmpty
          ? [Comic(id, '', id, null, null, '', source.key, null, null)]
          : await _catalog(source);
      if (source.loadComicInfo == null || source.loadComicPages == null) {
        throw StateError('This source does not support online reading');
      }
      SourceCheckResult? failure;
      // A removed or restricted first title must not condemn the whole source.
      for (final comic in samples.take(3)) {
        sample = comic;
        episode = null;
        imageKey = null;
        try {
          stage = SourceCheckStage.details;
          final Res<ComicDetails> details = await source
              .loadComicInfo!(comic.id)
              .timeout(timeout);
          final info = details.data;
          sample = Comic(
            info.title,
            info.cover,
            comic.id,
            info.subTitle,
            null,
            '',
            source.key,
            info.maxPage,
            null,
          );
          stage = SourceCheckStage.pages;
          episode = info.chapters?.ids.firstOrNull;
          if (info.chapters != null && episode == null) {
            throw StateError('No readable chapters found');
          }
          final pages = await source.loadComicPages!(comic.id, episode).timeout(
            timeout,
          );
          imageKey = pages.data.firstOrNull;
          if (imageKey == null) throw StateError('No comic pages found');
          stage = SourceCheckStage.image;
          await _loadImage(
            imageKey,
            source.key,
            comic.id,
            episode ?? '0',
          ).timeout(timeout);
          return SourceCheckResult(
            stage: stage,
            comic: sample,
            episode: episode,
            imageKey: imageKey,
          );
        } catch (e) {
          final result = SourceCheckResult(
            stage: stage,
            error: e.toString(),
            comic: sample,
            episode: episode,
            imageKey: imageKey,
          );
          if (failure == null || stage.index >= failure.stage.index) {
            failure = result;
          }
        }
      }
      return failure!;
    } catch (e) {
      return SourceCheckResult(
        stage: stage,
        error: e.toString(),
        comic: sample,
        episode: episode,
        imageKey: imageKey,
      );
    }
  }
}

class SourceCheckManager extends ChangeNotifier {
  static final instance = SourceCheckManager();
  final _results = <String, SourceCheckResult>{};
  final _checkedSources = <String, ComicSource>{};
  final _activeSources = <String, ComicSource>{};

  SourceCheckResult? resultFor(ComicSource source) =>
      identical(_checkedSources[source.key], source)
      ? _results[source.key]
      : null;

  void clear(String key) {
    _results.remove(key);
    _checkedSources.remove(key);
    _activeSources.remove(key);
    _running.remove(key);
    notifyListeners();
  }

  final _running = <String, Future<SourceCheckResult>>{};

  bool isChecking(String key) => _running.containsKey(key);

  Future<SourceCheckResult> check(ComicSource source, {String? comicId}) {
    if (identical(_activeSources[source.key], source)) {
      return _running[source.key]!;
    }
    _activeSources[source.key] = source;
    return _running[source.key] = _run(source, comicId);
  }

  Future<SourceCheckResult> _run(ComicSource source, String? comicId) async {
    // Yield so the active future is registered before listeners rebuild.
    await Future<void>.delayed(Duration.zero);
    notifyListeners();
    final result = await SourceAvailabilityChecker().check(
      source,
      comicId: comicId,
    );
    if (identical(_activeSources[source.key], source)) {
      _checkedSources[source.key] = source;
      _results[source.key] = result;
      _running.remove(source.key);
      _activeSources.remove(source.key);
      notifyListeners();
    }
    return result;
  }
}
