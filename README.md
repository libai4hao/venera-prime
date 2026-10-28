# venera next version


# venera-prime
[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)


A comic reader that support reading local and network comics.

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

## Build from source
1. Clone the repository
2. Install flutter, see [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install rust, see [rustup.rs](https://rustup.rs/)
4. Build for your platform: e.g. `flutter build apk`

## Local development and testing

Prerequisites:

- Flutter 3.41.4 (the repository also has `.fvmrc` for FVM users)
- Dart 3.11.1 (bundled with the Flutter SDK)
- Android builds: JDK 17, Android SDK platform 36, NDK `28.0.13004108`
- Windows builds: Visual Studio 2022 with the "Desktop development with C++" workload

Run unit and widget tests:

```sh
flutter pub get
flutter test --no-pub --concurrency=2
flutter analyze --no-pub
```

On Windows, `bash tool/dev_test.sh` (Git Bash) runs the same flow with a
process-local Git URL rewrite (`https://github.com/` to SSH) for the
repository's Git dependencies. This avoids changing the global Git
configuration on machines where GitHub HTTPS is unreliable. A PowerShell
equivalent is available as `tool/dev_test.ps1`; it requires the current
execution policy to allow local scripts.

Windows test notes:

- Some tests create symlinks. Enable Developer Mode (Settings → System → For
  developers) or expect those tests to fail without the symlink privilege.
- Tests that delete temporary directories may fail on Windows if a file is
  still open; rerun the individual test file to confirm.

Integration tests need a device:

```sh
flutter devices
flutter test integration_test/reader_spread_test.dart -d <device-id>
```

On Windows, use `python` for `tool/*.py` scripts; `python3` may resolve to the
Microsoft Store stub.

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

