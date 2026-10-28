# venera-prime 项目侦察报告

> 侦察方式：Glob / Grep 文件指纹扫描，未通读源码。
> 扫描时间：2026-10-28

## 1. 包清单

| 文件 | 是否存在 | 说明 |
|---|---|---|
| `package.json` | 否 | — |
| `pyproject.toml` | 否 | — |
| `go.mod` | 否 | — |
| `Cargo.toml` | 否 | — |
| `pom.xml` | 否 | — |
| `pubspec.yaml` | 是 | 主清单 |
| `packages/avif_native/pubspec.yaml` | 是 | Dart FFI 子包 |

**语言**：Dart / Flutter，包名 `venera`，版本 `2.6.3+263`，Dart SDK `>=3.8.0 <4.0.0`，Flutter `3.41.4`。

**主要依赖（pubspec.yaml）**：

- 数据/存储：`sqlite3`、`sqlite3_flutter_libs`、`path_provider`、`yaml`、`xml`、`archive`
- 网络：`dio`、`rhttp`、`html`、`webdav_client`、`crypto`、`pointycastle`、`enough_convert`
- 脚本引擎：`flutter_qjs`、`syntax_highlight`
- Flutter 生态：`flutter_inappwebview`、`desktop_webview_window`、`photo_view`、`scrollable_positioned_list`、`flutter_staggered_grid_view`、`flutter_reorderable_grid_view`、`sliver_tools`
- 系统集成：`window_manager`、`app_links`、`file_selector`、`flutter_file_dialog`、`share_plus`、`url_launcher`、`local_auth`、`battery_plus`、`flutter_saf`、`flutter_7zip`、`mobile_scanner`、`qr_flutter`
- 主题/UI：`dynamic_color`、`flex_seed_scheme`、`shimmer_animation`、`flutter_memory_info`、`display_mode`、`lodepng_flutter`
- 本地子包：`avif_native`

**开发依赖**：`flutter_test`、`integration_test`、`flutter_lints ^5.0.0`、`flutter_to_arch`、`flutter_to_debian`。

## 2. 框架指纹

| 指纹 | 是否命中 |
|---|---|
| `next.config.*` | 否 |
| `vite.config.*` | 否 |
| `webpack.config.*` | 否 |
| `manage.py` | 否 |
| `main.go` | 否 |
| `angular.json` | 否 |
| `analysis_options.yaml` | 是 |
| `rust-toolchain.toml` | 是（无 `Cargo.toml` / `.rs` 源码，仅工具链固定） |

**框架结论**：Flutter 跨平台应用，Material 风格，自建 `foundation` / `network` / `components` / `pages` / `utils` 分层；无 Next/Vite/React 等 Web 框架痕迹。

**平台工程目录**：`android/`、`ios/`、`linux/`、`macos/`、`windows/`、`debian/`。

## 3. 入口点

| 路径 | 角色 |
|---|---|
| `lib/main.dart` | 主入口（`material.dart`、`main_page.dart`、`auth_page.dart`、`window_manager`） |
| `lib/init.dart` | 初始化逻辑 |
| `lib/headless.dart` | 无界面/后台任务入口 |
| `android/app/src/main/kotlin/com/github/wgh136/venera/MainActivity.kt` | Android 原生入口 |
| `android/app/src/main/kotlin/com/github/wgh136/venera/UpdateFileProvider.kt` | Android 更新 FileProvider |

**代码组织（lib/）**：`components`、`foundation`、`network`、`pages`、`utils`，共 173 个 `.dart` 文件。

## 4. 工具链

| 文件 | 是否存在 |
|---|---|
| `tsconfig.json` / `.eslintrc*` | 否 |
| `Makefile` | 否 |
| `Dockerfile` / `Dockerfile.*` | 否 |
| `.github/workflows/main.yml` | 是 |
| `.fvmrc` | 是（Flutter 版本固定） |
| `.metadata` | 是（Flutter 项目元数据） |
| `analysis_options.yaml` | 是（Dart 静态分析） |
| `rust-toolchain.toml` | 是 |

**CI 工作流（main.yml）**：`Build ALL`，触发于 push / pull_request / workflow_dispatch；作业：`Validate_Version`、`Build_MacOS`、`Build_IOS`、`Build_Android`、`Build_Windows`、`Build_Linux`、`Build_Linux_ARM64`、`Release`、`Update_AltStore`。

**辅助工具（tool/）**：`android_debug.sh`、`build_appimage.sh`、`check_release_identity.py`、`check_version.py`、`generate_update_apk_fixtures.py`、`performance_audit_driver.dart`、`test_alt_store.py`、`test_follow_updates_android.sh`、`test_performance_android.sh`、`test_release_identity.py`、`comic_sources/manga_dex.js`。

**原生子包**：`packages/avif_native/`，含 Dart FFI 封装（`lib/src/avif_ffi.dart`）、C shim（`src/avif_shim.c`）、Android 预编译 `.so`、CMake 构建（`native/CMakeLists.txt`）、构建脚本（`hook/build.dart`、`tool/build_android.py`）。

## 5. 测试结构

| 项目 | 数量 / 路径 |
|---|---|
| 单元/组件测试 | `test/`，84 个 `*_test.dart` |
| 集成测试 | `integration_test/`，13 个 `*_test.dart` |
| 测试辅助 | `test/support/`（`avif_cases.dart`、`avif_fixtures.dart`、`background_feature_cases.dart`、`comic_author_cases.dart`、`data_sync_cases.dart`、`follow_updates_cases.dart` 等） |
| `jest.config.*` / `vitest.config.*` / `pytest.ini` | 否 |

**测试命名**：Dart 惯例 `*_test.dart`；无 `__tests__/`、`*.spec.*`。

**覆盖主题（抽样）**：应用更新、后台任务、缓存、CBZ/压缩包、漫画源、收藏夹、阅读器（分页/方向/边距）、数据同步/备份、历史迁移、性能审计、AVIF 编解码、发布流程校验。
