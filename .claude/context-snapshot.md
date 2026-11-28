# Venera Prime — 上下文快照

> 生成时间：2026-11-25 · 基于仓库 master 现状（已合入 upstream `056a419`，Venera Prime 2.8.1）
> 前一版快照：2026-11-23（2.8.0 时代，见 git 历史）。本版随 up/master → master 合并（2.8.1 功能与发布恢复提交）更新，并复核、修复 fork 遗留问题。

## 技术栈表

| 类别 | 技术 | 关键证据 |
|---|---|---|
| 语言 / SDK | Dart `>=3.8.0 <4.0.0`，Flutter `3.41.4`（FVM 固定），版本 `2.8.1+281` | `pubspec.yaml`、`.fvmrc` |
| 应用形态 | 跨平台漫画客户端：Android / iOS / Windows / macOS / Linux / Debian | `android/`、`ios/`、`windows/`、`macos/`、`linux/`、`debian/` |
| UI | Flutter Material 3；`dynamic_color`、`flex_seed_scheme`、自建组件库 | `lib/main.dart`、`lib/components/` |
| 状态管理 | 无第三方状态库；全局单例 + `ChangeNotifier` + `ListenableBuilder` | `lib/foundation/app.dart`、`appdata.dart` |
| 脚本引擎 | `flutter_qjs`（QuickJS 分支），启动注入 `assets/init.js` | `lib/foundation/js_engine.dart` |
| HTTP | `dio` 为主，本地 vendored `rhttp` 作为原生客户端适配器（含连接/发送/接收空闲超时与取消处理）；`webdav_client`（带超时） | `lib/network/app_dio.dart`、`packages/rhttp/` |
| 本地存储 | `sqlite3` 多库分离 + JSON 文件（`appdata.json`、`implicitData.json`）；搜索历史新版条目含来源/筛选/页码 | `lib/foundation/*.dart`、`search_history.dart` |
| Android SAF | 自研 `flutter_saf` 子包（path 依赖）：Kotlin 插件 + C++ `pathwrapper.cpp` + Dart `AndroidFile/AndroidDirectory`，descriptor 经 `SAFTaskWorker` 串行化、`Finalizer` 释放 | `packages/flutter_saf/` |
| 压缩 / 文档 | `archive`、`zip_flutter`、本地 vendored `flutter_7zip`；CBZ / EPUB / PDF 解析；解压有 canonicalize 目标、符号链接拒绝、大小/条目上限、流式 CRC 与原生写出边界防护 | `lib/utils/cbz.dart`、`epub.dart`、`archive_security.dart`、`packages/flutter_7zip/` |
| 图片 | `photo_view`、自定义 `ImageProvider` 链；AVIF 由 `avif_native` FFI 解码 | `lib/foundation/image_provider/`、`packages/avif_native/` |
| 安全 / 平台 | `crypto`、`pointycastle`、`local_auth`、`flutter_saf` | `pubspec.yaml` |
| 测试 | `flutter_test` 单元/组件测试（`test/` 105 个文件，含 `test/native/saf_file_io_test.cpp`）+ `integration_test/` 设备集成测试（17 个） | `test/`、`integration_test/` |
| CI / 发布 | GitHub Actions 六平台矩阵、版本校验、Release、AltStore 更新；新增手动触发的 `dispatch-release.yml` | `.github/workflows/main.yml`、`dispatch-release.yml`、`tool/` |

## 架构描述（3 句）

1. 这是一个本地优先的 Flutter 漫画客户端：`MaterialApp` 只挂载 `MainPage`，通过 `App` 持有的 root/main 双 Navigator 和 `context.to()` 扩展做栈式导航，`pages/` 负责界面、`components/` 提供通用控件、`foundation/` 承载领域逻辑与持久化。
2. 核心是「JS 漫画源运行时」：`ComicSourceParser` 把用户提供的 JS 源解析为 `ComicSource` 与 Dart 闭包，闭包经 `JsEngine.runCode` 调用 QuickJS 中的 `ComicSource.sources.<key>`，JS 再用 `sendMessage` 回调 Dart 实现的 `_http` / `html` / `cookie` / `convert` 等原生能力，结果映射为 `Comic`、`ComicDetails` 模型。
3. 所有外部操作统一返回 `Res<T>` 并写 `Log`；设置与搜索历史落 JSON（新版历史含来源/筛选/页码，可与旧版关键词模式切换），历史、收藏、本地库（含虚拟分类 `local_library.dart`）、稍后再读、阅读统计各自独立 SQLite，网络默认走 Dio（可切换 rhttp / dart:io，带分阶段超时），失败时回退并以用户可读文案呈现；Android 上 SAF 路径经 `IOOverrides` 映射为 `flutter_saf` 的 `AndroidFile`。

## 关键文件地图

| 路径 | 用途 |
|---|---|
| `pubspec.yaml` | Flutter 依赖、资源清单、Linux/Debian 打包元数据；`flutter_saf`、`rhttp`、`flutter_7zip` 为本地 path 依赖 |
| `lib/main.dart` | 进程入口：`--headless` 分流、初始化、`MaterialApp`、主题、鉴权、启动期项目提示与后台任务 Overlay |
| `lib/init.dart` | 启动编排：核心存储、CookieJar、数据库组件、JS 运行时、漫画源、更新检查 |
| `lib/headless.dart` | 无界面模式入口（后台任务/同步场景） |
| `lib/foundation/app.dart` | 全局单例 `App`：数据路径、双 Navigator Key、各 Manager 实例 |
| `lib/foundation/appdata.dart` | `settings`/`searchHistory` 的 JSON 持久化、sanitize、同步字段过滤、搜索进度 flush |
| `lib/foundation/search_history.dart` | 搜索历史条目模型：关键词/源/筛选/页码/schema，新版与旧版关键词模式并存 |
| `lib/foundation/context.dart` | `context.to()` / `pop()` / `toReplacement()` 导航扩展 |
| `lib/foundation/res.dart` | `Res<T>` 统一结果类型（`error` / `data` / `subData`） |
| `lib/foundation/comic_source/comic_source.dart` | `ComicSourceManager`：源装载、排序、更新状态与通知 |
| `lib/foundation/comic_source/parser.dart` | 解析 JS 源，生成 search / loadInfo / favorites 等 Dart 闭包 |
| `lib/foundation/comic_source/models.dart` | `Comic`、`ComicDetails`、`Comment` 等模型与 JSON 映射 |
| `lib/foundation/js_engine.dart` | QuickJS 单例与 JS↔Dart 消息桥（http / html / cookie / crypto / UI） |
| `lib/network/app_dio.dart` | `AppDio`（Dio + rhttp 适配）、连接/发送/接收空闲超时、敏感信息脱敏日志、HTTP 错误文案 |
| `lib/foundation/history.dart` | 历史 SQLite（`history.db`）建表、迁移、查询与写入 |
| `lib/foundation/favorites.dart` | 本地收藏 SQLite（`local_favorite.db`，按文件夹动态建表） |
| `lib/foundation/local.dart` | 本地漫画与下载管理（本地库 SQLite）、存储路径迁移/采纳已有目录、metadata 回填 |
| `lib/foundation/local_library.dart` | 本地库虚拟分类（`local_folders` / `local_placement` 表）：分类不移动实际文件 |
| `lib/foundation/read_later.dart` / `reading_statistics.dart` | 稍后再读 / 阅读统计 SQLite |
| `lib/utils/data_sync.dart` | WebDAV 与备份导入导出、跨设备同步（按修订号选备份、超时与批处理触发） |
| `lib/pages/main_page.dart` | 主界面：Home / Favorites / Explore / Categories 四页与侧栏动作 |
| `lib/pages/search_page.dart` | 搜索入口与新旧搜索记录切换，跳转 `SearchResultPage` 或聚合搜索 |
| `lib/pages/search_result_page.dart` | 搜索分页列表，绑定 `source.searchPageData.loadPage/loadNext`，退出时同步进度 |
| `lib/components/search_results_list.dart` | 搜索专用分页列表组件：页码恢复、游标源逐页补齐、页间分隔与页码标注 |
| `lib/utils/search_options.dart` | 搜索选项 schema 快照与白名单校验（选项变更回退第 1 页） |
| `lib/components/comic.dart` | 漫画卡片/网格/列表通用组件，点击进入 `ComicPage` |
| `lib/pages/comic_details_page/comic_page.dart` | 详情页：`loadComicInfo`、章节、收藏、评论、进入阅读器 |
| `lib/pages/reader/reader.dart` | 阅读器：分页、手势、预载，节流写回历史；连续/瀑布流/双页模式 |
| `lib/pages/reader/waterfall.dart` | 瀑布流跨章节连续阅读（`_WaterfallMode`，`part of reader.dart`） |
| `lib/utils/reader_spread_geometry.dart` | 双页排版几何：宽图判定、统一页高、封面/尾页空位预留 |
| `lib/utils/reader_page_layout.dart` | 阅读页排版（单页/双页/连续，配对与聚焦） |
| `lib/utils/chapter_title_sort.dart` | 章节名混合排序：中英文前缀、中文/全角数字、小数话号统一比较 |
| `lib/pages/local_comics_page.dart` | 本地漫画列表：体积/来源显示、虚拟分类、批量操作、多选 |
| `lib/pages/project_notice.dart` | 首次确认的项目说明（`ProjectNoticeReceipt` 独立存储，不入 appdata/备份） |
| `lib/foundation/comic_type.dart` | `ComicType`（local / 网络源 key），参与模型身份判定 |
| `packages/avif_native/` | AVIF 解码 FFI 子包（C shim、Android `.so`、CMake 构建） |
| `packages/flutter_saf/` | Android SAF 存储访问子包：Kotlin `FlutterSafPlugin` + C++ `pathwrapper.cpp` + Dart `AndroidFile/AndroidDirectory`（stat、字节与文本 IO、真实文档 ID） |
| `packages/flutter_7zip/` | 从上游固定提交 vendored 的 7z FFI 插件；本地补丁校验解码块边界与文件写入结果 |
| `.github/workflows/main.yml` | 六平台构建、版本校验、发布与 AltStore 更新 |
| `.github/workflows/dispatch-release.yml` | 手动触发（workflow_dispatch）的发布流程 |
| `doc/release-policy.md` | 发布流程与版本约束（`AGENTS.md` 强制先读） |
| `doc/CODE_REVIEW-2026-11-23-merge-upstream.md` | 本次合并（`04ff270..120b046`）的两轴评审记录 |

## 5 条最关键编码约定

1. **命名与文件组织**：文件 `snake_case`、类 `PascalCase`、全局单例小写（`App`、`appdata`）；大模块用 `part` / `part of` 拆分（`comic_source.dart` 拆出 models/parser/types 等，`reader.dart` 拆出 waterfall 等）。UI 文案一律 `"Text".tl` 或 `"… @x".tlParams({...})`，新增文案同步 `assets/translation.json`。
2. **错误处理**：跨层返回 `Res<T>`（`Res.error(...)`），不以异常穿透 UI；底层 `try/catch` 后调用 `Log.error("Tag", message, "$e\n$s")`；可重试初始化统一用 `Init` mixin 的 `ensureInit()`；数据库损坏时先重命名为 `.corrupt.<timestamp>` 再重建。
3. **导航**：不使用命名路由；页面通过构造函数接收参数，统一 `context.to(() => Page())`、`App.rootContext.to()`、`toReplacement()`；全局只维护 root/main 两个 `NavigatorState` Key。
4. **状态与持久化**：单例 + `ChangeNotifier` + `ListenableBuilder`，不引入第三方状态管理；设置存 JSON（写前 sanitize、`atomicWriteString` 原子落盘），业务数据各自独立 SQLite 文件，原生 sqlite 句柄不跨 isolate 共享。
5. **测试与提交**：单元/组件测试放 `test/<feature>_test.dart`（105 个），设备级流程放 `integration_test/`（17 个），测试用临时目录 + `addTearDown` 自清理；提交信息为英文祈使句，部分带 `feat:` / `fix:` / `ci:` 前缀；发布相关改动必须先读 `doc/release-policy.md`，不得擅自升版或改动既有 Release。

## 已知风险指针（2026-11-25 复核）

- 上游 2.8.1 已补齐 SAF stat/文本 IO、真实文档 ID 与写入结果校验；本轮补充了字面管道符文件名回归，但真机 DocumentsProvider 场景仍需按 `AGENTS.md` 的独立测试包流程验证。
- 本地库多选身份、全量刷新通知与体积缓存，搜索游标恢复/空页继续/进度落盘，以及阅读页越界映射均已修复并补回归测试。
- ZIP/7z 解压已增加声明大小、CRC、条目总量和原生写出边界校验；Windows 7z 插件单独构建与原生有效/伪造夹具检查通过，完整 Windows 应用构建仍受既有 `rhttp/ring` 编译失败阻断。
- 历史问题与复核结论见 `doc/CODE_REVIEW-2026-11-23-merge-upstream.md`；未执行的真机与第三方源验证不得表述为通过。
