# Source readability, chapter navigation and Android updates

## Comic sources

Installing a source from a URL, file or source library automatically checks a sample comic. The source settings page shows the result and offers **Check readability** to inspect it or check again after logging in or changing settings. A successful check loads a catalog, comic details, chapter pages, then downloads and decodes a page image through the source's normal image hooks. The dialog shows the sample and an image preview.

The check bypasses the image cache, tries up to three samples and uses a 15-second limit for each loading stage. A failed or empty catalog can fall back to another explore page. Sources that expose no catalog can be checked by entering a comic ID. Failure reports the stage and source error; failure of a sample does not assert that every title is unavailable. Results are kept for the current session and invalidated when a source is replaced or deleted.

## Reading

Edge taps resolve their configured direction before crossing a chapter boundary. The same reading-order navigation is used for gallery keyboard arrows, mouse wheel and volume keys. Advancing past the last page opens the next chapter; moving back from the first page opens the last page of the previous chapter. Chapter-group boundaries are preserved. Continuous reading also recognizes the actual scroll boundary when several short images remain visible, after images have finished loading.

Swipe direction continues to follow the reading mode, independently of the reverse-tap preference. Gallery and continuous, left-to-right, right-to-left and top-to-bottom modes are covered by widget tests for both taps and swipes.

## Android updates

The update dialog selects an APK using Android's supported ABI order, with a universal APK fallback. **Download and install** downloads inside the app with progress and cancellation. File size and the release's SHA-256 digest (when provided) are checked before exposing the completed file to installation. Failed or cancelled downloads remove the partial file.

The native installer verifies the package name, newer version code and installed signing certificate. It shares only the updater's cache subdirectory through a non-exported FileProvider. If Android requires permission to install apps, granting permission returns to the pending update and opens the system installer. Denying permission leaves the downloaded APK available to retry. Android still requires the user's system installation confirmation. Other platforms and releases without a compatible APK retain a clearly labelled release-page fallback.

## Validation

Run with the Flutter version pinned in `.fvmrc`:

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub test/app_update_test.dart test/source_availability_test.dart test/reader_chapter_direction_test.dart test/reader_scrubbing_test.dart test/reader_spread_test.dart
```

On an Android device, verify the full upgrade with two builds signed by the same key: allow/deny install permission, return and retry, cancel a download, verify retained user data after upgrading, and reject an APK signed by another key. Device installation is a separate check from Flutter tests and Kotlin compilation.
