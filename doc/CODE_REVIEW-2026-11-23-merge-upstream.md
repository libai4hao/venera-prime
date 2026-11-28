# 代码评审：上游合并 04ff270..120b046（2026-11-23）

- **评审范围**：`git diff 04ff270..120b046`（上游 venera-prime 2.7.0 → 2.8.0 的 8 个提交，130 文件 +10959/−1202）
- **评审方式**：双轴并行静态评审（Standards 约定轴 + Spec 规格轴，各由独立子代理完成）。本机 D 盘工作目录下 dart/flutter 工具链假死，全部结论来自代码走读，未执行测试。
- **规格文档基线**：doc/release-2.7.0.md、release-2.7.0-checks.md、release-2.7.1.md、release-2.7.2.md、release-2.8.0.md、release-2.8.0-checks.md、issue-audit-2026-11-03.md、issue43-saf-regression-2026-11-06.md、webdav-audit-2026-11-04.md

---

## 一、Standards 轴（约定符合性）

### 硬违规

**S1｜新 UI 文案未同步 `assets/translation.json`（违反约定 1）。** 本 diff 新增 3 处用户可见文案，`.tl` 找不到键时静默回退英文，中文用户会看到英文：

| 位置 | 文案 |
|---|---|
| lib/components/search_results_list.dart:101、:108、:127 | `'Unknown error'.tl` |
| lib/pages/home_page.dart:1614 | `'No comics'.tl` |
| lib/pages/reader/waterfall.dart:172 | `'Chapter'.tl` |

已核实 translation.json 中不存在这三个键（仅有相近的 "No comics to check"，是另一条文案）。其余本 diff 新增的约 25 条文案均已同步 zh 与 zh-TW。**修复成本极低**：三键补进 translation.json 即可。

**S2｜异常跨层未走 `Res<T>`（可商榷）。** lib/foundation/local_library.dart:25、:34、:67 向 UI 层抛 `ArgumentError`；lib/pages/local_comics_page.dart:200 用裸 `catch (_)` 接住并弹通用提示，无 `Log.error`。异常没有穿透 UI，但偏离了约定 2 的 `Res.error` 模式。lib/pages/project_notice.dart:62、:80 同样吞错不打日志（UI 层内，程度轻）。

### 基线 smell（均为判断题，非违规）

- **重复代码**：search_results_list.dart:109-112 与 :142-145 在 `loadPage`/`loadNext` 两分支重复「已存页码不可用」提示+回页逻辑；整个类有意绕开 components/comic.dart 的现成分页以做搜索隔离（:11 有注释说明），属有意取舍。
- **Refused Bequest**：`AndroidDirectory`/`AndroidFile` 实现 `dart:io` 接口但约 20 个成员 throw `UnimplementedError`（packages/flutter_saf/lib/flutter_saf.dart:582-619、:909-1016）。flutter_saf 为 vendored 上游代码（UPSTREAM.md 记录本地补丁），vendored 状态优先于基线要求。

### 核实为合规

- **发布纪律**（doc/release-policy.md）：pubspec.yaml `2.8.0+280`、app.dart `"2.8.0"`、doc/release-2.8.0.md 标题一致；release 文档无 `Fixes/Closes/Resolves #` 关键字。
- **约定 3/4/5**：导航统一 `context.to(() => Page())`；新设置键走既有 appdata JSON 路径；waterfall.dart 正确使用 `part of`；提交信息英文祈使句；新测试用内存库/临时目录 + `tearDown`。
- app_dio.dart、local.dart、reader.dart 的错误处理均正确配对 `catch` 与 `Log.error(tag, error, stack)`。

---

## 二、Spec 轴（规格符合性）——无发现

八个规格文档逐条追入 diff，**未发现缺失需求、范围蔓延或实现错误**，包括易漏的细节：

- 2.7.2「旧备份缺 searchRecords 保留本地记录」：恢复以 `data.containsKey('searchRecords')` 为门（lib/foundation/appdata.dart:367-369），显式空列表才清除（appdata.dart:74-78）。
- 2.7.0「翻页合并本地保存，离开搜索时同步」：`updateSearchPage` 以 `saveData(false)` 只写本地，`flushSearchProgress` 在 dispose 触发（lib/pages/search_result_page.dart:119、lib/pages/aggregated_search_page.dart:66）。
- 2.8.0「选项变化回退默认值及第一页」：schema 不匹配 → 默认值 + 第 1 页 + 用户提示（lib/pages/search_result_page.dart `validateOptions`）。
- 2.7.2 修订号优先备份比较、15s/60s/60s 超时、webdav-audit 四处自动同步触发缺失均已补齐（lib/foundation/data_sync.dart；history.dart、image_favorites.dart:308-311、read_later.dart、reading_statistics.dart）。
- 2.8.0 SAF 句柄数组显式复制释放（packages/flutter_saf/lib/flutter_saf.dart:453-455、:493-495）、JNI attach 作用域（pathwrapper.cpp:56、:63）、音量键待到达页（lib/pages/reader/reader.dart:1065-1078、:1088-1094）。
- 2.7.1 瀑布流阅读记录随可见章节更新（lib/pages/reader/waterfall.dart:223-230），边界可经 `errors` map 重试。
- 2.7.0 迁移分块复制 + SAF 短读安全重开（lib/utils/io.dart:188-206）。

130 个变更文件全部可追溯到规格功能、其测试、发布设施（dispatch workflow）或 vendored flutter_saf。**注意**：纯静态走读，未执行测试（各区域均有对应测试文件，如 test/search_restore_test.dart、test/rhttp_transport_timeout_test.dart、test/local_storage_migration_test.dart）。

---

## 三、master HEAD 已知缺陷核对（与 2026-11-16 评审交叉）

2026-11-16 评审（doc/CODE_REVIEW-2026-11-16-merge-local.md，对象 origin/master...CC_vibe_coding）的修复在 review-2026-11-16 分支 6c31c2d，**未合入 master**。本次已逐条在 master HEAD（120b046）核实其存在状态：

| 编号 | 缺陷 | HEAD 状态（证据） |
|---|---|---|
| P1-1 | SAF 下 metadata.json/ComicInfo.xml 读不到（AndroidFile 文本 API 缺口 + 外层静默吞错） | **仍存在**：flutter_saf.dart 文本方法仍 throw UnimplementedError（:175、:585-605 一带） |
| P1-2 | 多选高亮刷新后丢失（selectedComics 以 LocalComic 实例为键） | **仍存在**：local_comics_page.dart:42 仍为 `Map<LocalComic, bool>`，无 _selectionKey |
| P2-4 | rescan/下载完成全量重建风暴（逐条 notify + _sizes.clear() + 逐 tile 递归扫盘） | **仍存在**：local.dart 无批量 notify 参数；local_comics_page.dart:73 `_size` 仍逐次全量递归 |
| P2-6 | main.dart _scheduleStartup post-frame 回调无 catch，异常致更新检查/自动源更新永久失效 | **仍存在**：main.dart:97 _scheduleStartup 无 catch 配对 |
| P2-7 | cursor 源恢复串行 N 次请求且空页误判到底 | **仍存在**：search_results_list.dart 无 _maxRestorePages 上限 |
| P3-1 | home_page _compactHome build 内重复解析 JSON | **仍存在**：home_page.dart 无布局缓存 |
| P3-3 | 瀑布流边界显示原始 error.toString() | **仍存在**：waterfall.dart:137 `errors[forward] = error.toString()` |
| P3-4 | _size() 无兜底，扫盘异常直接崩 | **仍存在**：local_comics_page.dart:73-81 无 try/catch |
| P3-5 | search_result_page _entry! 空断言 | **仍存在**：search_result_page.dart:62、:195 |
| P2-1/2/3 | adoptExistingPath 事务顺序/幂等/冲突策略 | **不适用**：master 无 adoptExistingPath（fork 专属功能） |
| P2-8 | build-windows.yml v* tag 触发与 release-policy 冲突 | **不适用**：master 无该 workflow（仅 fork 分支有） |
| P3-7 | tile 章节数空时回退总章节数误导 | 未复核（HEAD 的 tile 代码未见对应引用，待确认） |

**结论**：master HEAD 携带 9 项已确认的既有缺陷（2×P1 + 3×P2 + 4×P3），修复已存在于 review-2026-11-16 分支 6c31c2d，可整体 cherry-pick 或合并该修复提交。

---

## 四、总结与建议

**本次合并本身质量良好**：Spec 轴零发现，Standards 轴仅 1 条硬违规（3 处漏翻译）+ 1 条可商榷偏离。上游代码符合仓库既有约定，发布纪律完整。

建议后续动作（按优先级）：

1. **补 3 处翻译**（S1）：`Unknown error`、`No comics`、`Chapter` 三键进 translation.json 的 zh 与 zh-TW 块。
2. **合入 6c31c2d 修复**：解决 P1-1/P1-2 等 9 项既有缺陷；该分支基于旧 master，合入前需 rebase 到 120b046 并复跑测试。
3. **可选**：local_library.dart 改走 `Res<T>` + 补 `Log.error`（S2）。
4. **发布前**：在可用环境复跑 `dart analyze` 与 `flutter test`（本次为纯静态评审）；真机集成测试按 AGENTS.md 要求先核实测试包名。

---

## 五、2026-11-25 上游 2.8.1 合并与遗留问题复核

> 前四节保留 2026-11-23 评审时的历史结论；其中标记为“仍存在”的缺陷不能用于描述当前工作树。以下记录以 master 合并提交 `fc2bab8`（父提交 `ddcb093` 与 upstream `056a419`）为基线。

### 上游相对本 fork 的主要更新

- **2.8.1 应用功能**：修复网络取消/超时后的延迟回调原生崩溃（#55）；补齐 Android SAF 属性查询与文本 IO（#53）；实现通用 DocumentsProvider、真实文档 ID、离线目录保留和写入失败上报（#54）；修复图片缓存刷新与长按控制器生命周期（#49）。
- **外观与导航**：新增 18 个主题预设、RGB/HEX 自定义颜色；冷启动外部链接改为等待漫画源、首页导航和启动解锁完成后处理，并支持已知链接结构的页码跳转。
- **依赖与发布设施**：本地 vendored `packages/rhttp`；发布工作流增加机器人失败任务重试、从已成功六平台构建恢复发布的校验；AltStore 更新到 2.8.1，并补充发布恢复规范与执行记录。
- **合并结果**：未发现需要人工裁决的文本冲突；上游功能与 fork 既有搜索、本地库、瀑布流和压缩包加固改动保持兼容。

### 本轮确认并修复的问题

| 问题 | 处理结果 |
|---|---|
| S1 及本轮新增 UI 文案缺少翻译 | 在 `assets/translation.json` 的简中、繁中块补齐 `Unknown error`、`No comics`、`Chapter` 及两条新提示 |
| P1-1 SAF 文本元数据读取 | 由上游 2.8.1 修复；补充字面管道符文件名读写回归 |
| P1-2 本地库刷新后多选高亮丢失 | 以漫画 ID 与来源组成稳定键，刷新后把选中项重新绑定到当前模型实例 |
| P2-4 全量刷新通知与体积缓存风暴 | `LocalManager.add` 增加兼容性 `notify` 参数，刷新批量通知；仅在章节元数据变化时移除对应体积 Future |
| P2-6 启动 post-frame 异常使更新检查失效 | 增加异常隔离与日志，失败时仍恢复启动完成状态 |
| P2-7 游标恢复无限重放与空页误判到底 | 首次恢复最多重放 5 页；不可跳转时说明原因；连续模式空页继续加载 |
| P3-1 首页布局重复解析 | 按 settings 中的布局对象身份缓存解析结果 |
| P3-3 瀑布流展示原始异常 | 原始异常写入日志，界面显示可重试的本地化文案 |
| P3-4 本地体积扫描异常 | 记录日志并交给现有 `FutureBuilder` 错误分支显示 `Unavailable` |
| P3-5 搜索条目空断言 | 使用当前关键词、来源和选项构造临时身份，移除 `_entry!` |
| ZIP/7z 解压边界与完整性 | ZIP 改为流式有界写出并校验声明大小/CRC；7z 校验原生解码块边界、实际大小、CRC 与写入结果，失败清理部分文件 |
| 阅读页映射越界 | `ReaderPageLayout.pageForImage()` 对陈旧历史记录钳制到有效页范围 |
| 搜索进度落盘失败 | 保存失败时恢复 dirty 状态，后续 flush 可重试 |
| 本地元数据与文件夹操作静默失败 | 补 `Log.error`，保持公开 API 和现有用户提示不变 |

### 验证结果与未覆盖范围

- `flutter analyze`：**No issues found**。
- 本轮直接相关测试串行运行：**48 项全部通过**，覆盖压缩包、阅读页、瀑布流、本地库、搜索恢复/进度、首页布局、外部链接和项目说明。
- ZIP/7z 原生检查：有效与伪造声明大小夹具均符合预期；Windows `flutter_7zip` 插件单独 Release 构建成功。
- 版本、翻译 JSON 与 AltStore JSON 校验通过；排除 vendored 包后的暂存差异 `git diff --cached --check` 通过。`packages/flutter_7zip` 为保持上游固定提交原样，保留其既有行尾空白，全量暂存差异检查因此报告 1823 行 vendored 空白提示，未改写第三方源码。
- 此前 Windows 全量测试为 **371 通过、17 跳过、24 失败**；失败集中在既有原生 DLL 缺失、Windows 路径分隔符、临时文件占用和 webview 测试环境，不能据此声称全量测试通过，也未逐项证明均为基线问题。
- Windows 完整应用/集成测试仍受既有 `rhttp` 的 `ring v0.17.14` C 编译失败阻断；Android SAF 真机集成测试本轮未执行，执行前必须按 `AGENTS.md` 独立构建并用 `aapt dump badging` 核实测试包名。
- SAF `openRead`/`openWrite` 当前没有实际调用路径，为避免扩大 API 改动未补实现；`local_library.dart` 的 `ArgumentError` 契约保持不变，仅在 UI 边界补日志。
