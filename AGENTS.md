# 项目约定

准备版本、编写 Release 说明或执行发布时，先阅读并遵循 [发布规范](doc/release-policy.md)。用户明确指定的版本和发布范围优先；不得擅自升版、关闭 issue 或更改既有 Release。

## 这是什么

Venera Prime：Flutter 漫画阅读器，一套 Dart 代码出 Android / iOS / Windows / macOS / Linux（另加 debian / AppImage / AltStore 打包）。`lib/` 下 173 个 Dart 文件。漫画源的抓取逻辑是 JavaScript，不写在 Dart 里。

下文所有 `路径:行` 以 `04ff270`（v2.6.3）为基准，改代码前若行号对不上，按文件内的符号名搜索。

## 命令

版本钉死，别升级：

- Flutter `3.41.4`（`.fvmrc`、`pubspec.yaml:9`），Dart `>=3.8.0`（`pubspec.yaml:8`）
- Rust `1.85.1`（`rust-toolchain.toml`）：仓库里没有任何 Rust 源码（`git ls-files '*.rs'` 为空），但 `rhttp` 等依赖在构建期编译 Rust。`flutter build` 需要它，`flutter test` 不需要

```sh
flutter pub get
flutter analyze --no-pub          # 唯一的静态检查
flutter test --no-pub             # 全量：84 个 test/*.dart（另 test/support 10 个共享用例表）
flutter test --no-pub test/channel_test.dart test/reader_spread_test.dart
```

来源身份体检 / 修复（背景见「架构约束」里的 hashCode 说明）：

```sh
dart tool/source_identity.dart verify  --data <dataPath>                     # 只读，有孤儿 exit 1
dart tool/source_identity.dart recover --data <dataPath> --apply             # 默认 dry-run，--apply 才写
dart tool/source_identity.dart recover --data <dataPath> --map 12345=comic_source_key
```

**CI 不跑测试，也不跑 analyze。** `.github/workflows/main.yml` 全篇只有 `python3 tool/check_version.py` 和各平台 `flutter build`。CI 绿灯不代表测试通过，本地跑。

构建的真实入口（CI 用的不是裸 `flutter build`）：

| 平台 | 命令 | 证据 |
| --- | --- | --- |
| Windows | `flutter pub get` → `python windows/build.py` | `.github/workflows/main.yml:256-258` |
| Linux | `flutter pub get` → `python3 debian/build.py x64` → `dart run flutter_to_arch` → `bash tool/build_appimage.sh x86_64` | `.github/workflows/main.yml:276-291` |
| Android | `flutter build apk --release`（需 `android/release.keystore` + `android/key.properties`） | `.github/workflows/main.yml:194-229` |
| macOS / iOS | `flutter build macos --release` / `flutter build ios --release --no-codesign` | `.github/workflows/main.yml:116,154` |

## 架构约束

**没有依赖注入，没有 Provider / Bloc / Riverpod。全局状态是模块级单例。**

- `final App = _App()`（`lib/foundation/app.dart:127-128`）：路径、`rootNavigatorKey`、history / favorites / local / readLater / readingStatistics 五个管理器
- `appdata`（设置）、`ComicSourceManager()`（工厂单例，`lib/foundation/comic_source/comic_source.dart:40-44`）、`JsEngine()`（`lib/foundation/js_engine.dart`）
- 新增长生命周期服务：`with Init` mixin，实现 `doInit()`，外部只调 `ensureInit()`。它幂等且失败可重试（`lib/utils/init.dart:6-31`）；自己写 `bool _inited` 会漏掉并发首调
- 页面互刷用 `ChangeNotifier` + `App.forceRebuild()`（`lib/foundation/app.dart:118-124`）；需要按键反查某个 State 时用 `GlobalState` / `AutomaticGlobalState`（`lib/foundation/global_state.dart`）

**启动顺序有序，核心失败要降级不要崩。**

`lib/main.dart:21` → `lib/init.dart:54 init()` → `App.init()`（`lib/foundation/app.dart:88`，落 data/cache 路径）→ `App.initComponents()`（`lib/foundation/app.dart:97-106`，appdata → history → favorites → local → readLater → readingStatistics **逐个 await**）→ 翻译 / OpenCC → 缓存维护 → `unawaited` 异步初始化漫画源（`lib/init.dart:105-112`）。

- 核心存储失败必须 `return InitializationFailure(...)`：主界面会渲染重试页且**不动用户已有数据**（`lib/main.dart:219-232`、`lib/main.dart:366`）。不要在 init 里裸抛
- 非核心失败用 `Log.error` 吞掉继续（`lib/init.dart:66-93`）
- `Log` 的文件落盘依赖 `App.isInitialized`（`lib/foundation/log.dart:45`），初始化前打日志只进内存

**持久化两条路，别混。**

- 设置 / 偏好 → `appdata.settings['key']`，落单个 `appdata.json`。读入时按 key 校验类型、深度 8、字符串 1MB、列表 10000 项，**非法值直接丢弃并打 warning**（`lib/foundation/appdata.dart:25-78`）。加新设置项必须保证旧值能通过类型校验，否则用户升级后该项静默丢失。写盘统一走 `appdata.saveData()`（原子写 + 串行化 + 触发 WebDAV 同步，`lib/foundation/appdata.dart:80-111`）
- 结构化业务数据 → SQLite，每个域一个库文件，用 `package:sqlite3` 直接 `sqlite3.open`：history（`lib/foundation/history.dart:239`）、favorites（`lib/foundation/favorites.dart:329`）、local（`lib/foundation/local.dart:336`）、read_later（`lib/foundation/read_later.dart:101`）、reading_statistics（`lib/foundation/reading_statistics.dart:92`）、cookie（`lib/network/cookie_jar.dart:20`）、cache（`lib/foundation/cache_manager.dart:65`）。新表加到对应域，不要为单个功能新开一个库文件

**漫画源是 JS，不在 Dart 里写抓取逻辑。**

源脚本在 `${App.dataPath}/comic_source/*.js`，由 QuickJS（fork 的 `flutter_qjs`）执行，Dart 侧只做解析与调度：`lib/foundation/comic_source/comic_source.dart:58-75`。JS 侧 API 见 `doc/js_api.md`，源写法见 `doc/comic_source.md`。

- `lib/foundation/comic_source/comic_source.dart` 是一个 library + 5 个 `part`：`category` / `favorites` / `parser` / `models` / `types`（`:27-35`）。改这些子文件时它们**不能有自己的 import**，只能借主文件的 import；新增子文件要同步加 `part` 指令

**漫画的来源身份是 `source.key.hashCode`，不是稳定 ID。** 所有落库的来源列（`history.type`、收藏夹表 `type`、`local.db/comics.comic_type`、`read_later.comic_type`、`reading_statistics.comic_type`）都是这个 int，本地库固定 `0`（`lib/foundation/comic_type.dart:32-38`、`lib/foundation/comic_source/comic_source.dart:287-289`）。反查是线性比较 hashCode（`comic_source.dart:51-52`）。后果：改源 `key`、或 Dart 版本/平台换了哈希算法，旧条目会退化成 `Unknown:<int>` 并失去更新/跳转能力。写迁移或导入代码时**不要把唯一的来源身份塞进 int**，能加 `source_key` 文本列就加（`read_later.db` 有，`history`/收藏夹没有）；修不回来时用 `tool/source_identity.dart`，它按 `read_later.source_key` → `image_favorites.source_key` → `folder_sync.source_key` → `downloading_tasks.json` 的顺序反推 key，再按当前运行时重算。

**分层是约定，不是强制约束。**

`lib/foundation/`（领域 / 存储 / 服务）、`lib/pages/`（60 个页面，大页面再拆子目录）、`lib/components/`（通用组件）、`lib/utils/`、`lib/network/`。边界已经漏了：`lib/foundation/comic_source/comic_source.dart:15-16` 反向 import 了 `lib/pages/` 的两个页面。新代码按目录语义放，不要为了"纯净"启动大重构。

## 编码约定

- 日志用 `Log.error(title, content[, stack])` / `Log.warning` / `Log.info`（`lib/foundation/log.dart:90-104`）。`avoid_print` 在 lint 里被关掉了（`analysis_options.yaml:26`），`print` 不会报错——但项目里一律走 `Log`
- 导航用 `context.to(() => SomePage())` / `context.toReplacement(() => ...)`（`lib/foundation/context.dart:17-25`），底层是 `AppPageRoute`。不要直接 `Navigator.push(MaterialPageRoute(...))`，会丢转场与返回键行为
- 界面文案直接写中文 / 英文，渲染处加 `.tl`，运行时查 `assets/translation.json`（`lib/utils/translations.dart:17`）。没有 ARB / codegen，改文案直接改那个 json
- 全局单例故意大写首字母并配 `// ignore: non_constant_identifier_names`（`lib/foundation/app.dart:127`）。沿用这个形态，不要为了 lint 干净改成小写
- 文件名 snake_case，类名 PascalCase；测试 `test/<feature>_test.dart`，多平台共享用例表放 `test/support/<feature>_cases.dart`
- 提交信息：英文一句话祈使句。实测形态见 `git log --oneline`：`Repair legacy read later database migration`、`Simplify release completion and make artifact verification optional`

## 完成标准

改完 Dart 代码，下面两条都要有实际输出为证：

```sh
flutter analyze --no-pub
flutter test --no-pub test/<相关>_test.dart
```

涉及启动顺序、漫画源、阅读器、下载、数据同步的改动，加跑对应 `integration_test/`（13 个）。跨平台改动要说明在哪个平台验证过：**构建成功不等于功能验证**（`doc/release-policy.md:56`）。

## 版本

`pubspec.yaml:5`、`lib/foundation/app.dart:18`、`doc/release-X.Y.Z.md` 首行、git tag 四处必须一致，用 `RELEASE_TAG=vX.Y.Z python3 tool/check_version.py` 核验（`doc/release-policy.md:8`）。发布提交身份固定 `Anonymous <anonymous@users.noreply.github.com>`（`doc/release-policy.md:60`）。

## 文档索引

- `doc/release-policy.md` —— 发布规范，写 Release 前必读
- `doc/comic_source.md` / `doc/js_api.md` —— JS 漫画源开发
- `doc/headless_doc.md` —— `--headless` CLI 模式（入口 `lib/main.dart:22`、`lib/headless.dart:17`）
- `doc/source-check-reader-update.md` —— 验证命令配方与阅读器行为约定
- `fast-coding-doc/入门指南.md` —— 上手路径、目录地图、任务对照表
- `tool/source_identity.dart` —— 来源身份体检与修复，测试在 `test/source_identity_test.dart`
