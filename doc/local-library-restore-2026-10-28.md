# 本地库元信息与零拷贝恢复（2026-10-28）

本轮在 `CC_vibe_coding` 分支完成，提交：

- `c0edde1` 本地漫画列表显示作者、来源、语言、章节/页数
- `c0fd5fa` 恢复本地下载支持零拷贝复用老目录，并新增冲突副本处理
- `cd6b2ea` iOS/macOS 持久化安全作用域访问

未升版、未推送、未发布，未修改既有 Release 或 issue。

## 一、本地漫画列表元信息

### 入口

本地漫画库列表（详细/简洁两种显示模式）。

### 行为

- 详细模式在标题下显示：
  - 作者（人像图标）
  - 来源（当前本地目录或漫画源名称）
  - 语言
  - 实际已下载章节数
  - 磁盘实际图片页数
- 原有 tags 标签区域保留，信息行位于标题与 tags 之间。
- 简要模式在标题下增加一行紧凑元信息，超长省略。
- 缺失字段自动隐藏；语言不再与原有 badge 重复显示。
- 旧记录首次打开本地库时后台回填语言与页数，每个应用会话一次。

### 数据

- `local.db` 的 `comics` 表新增 `language TEXT`、`page_count INTEGER`，启动时通过 `PRAGMA table_info` 自动迁移旧库。
- `LocalComic` 新增可空字段 `language`、`pageCount`，不影响现有构造点和其它导入流程。
- 页数在导入/扫描时按实际图片文件统计；下载任务使用已下载图片总数。
- 不将总页数写入 `maxPage`，避免影响阅读进度语义。

## 二、恢复本地下载：零拷贝

### 标准流程

1. 先通过「导入 App 数据」导入老版本应用数据，确保当前 `local.db` 已包含老版本漫画记录。
2. 打开「导入漫画 → 恢复本地下载」。
3. 选择老版本下载目录（允许目录中已有内容）。
4. 只读扫描该目录的直接子目录；每个子目录视为一部漫画。
5. 与当前数据库去重：
   - 规范化绝对路径相同
   - 标题相同
   - 目录名相同
   任一命中即跳过。
6. 将当前本地存储路径零拷贝切换到所选目录：只更新 `local_path` 与内存中的 `LocalManager.path`，不复制、不移动、不清空文件。
7. 只把缺失漫画写入数据库；已存在记录不重复添加。
8. 重复执行结果幂等。

### 现有记录兼容

切换路径前按磁盘存在性处理已有相对路径记录：

| 情况 | 处理 |
| --- | --- |
| 仅旧路径存在 | 改写为绝对路径，`managedByApp=false`；仍可读取，但库删除不会删除文件 |
| 仅新目录存在 | 保持相对路径，切换后指向新根 |
| 新旧都存在 | 保持相对路径作为当前记录；旧路径副本进入冲突列表 |
| 绝对路径记录 | 保留原路径，切换后重算 `managedByApp` |

切换后统一重算 `managedByApp`：位于新根内且路径安全时为 `true`，恢复后的漫画按普通本地漫画处理，删除跟随「同时删除文件」选项。

### 路径校验

- 必须存在、可写。
- 不能与当前路径相同。
- 不能位于当前路径内部，也不能包含当前路径。
- 有下载任务进行中时拒绝切换。
- 切换失败时尝试回滚 `local_path` 与内存路径。

## 三、冲突副本列表

当同一目录名同时存在于旧路径和新根时，进入独立冲突页面：

- 展示漫画标题、当前有效路径、旧路径副本路径。
- 支持单项或批量：
  - 删除旧副本：只删除旧路径下的目录，当前副本保留。
  - 重命名并保留：旧副本改名为 `原名 (old copy)`，重名自动追加 `(2)` 等。
  - 暂不处理。
- 删除/重命名前校验：
  - 目标必须在旧根内，且不是旧根本身。
  - 路径链不得包含符号链接。
  - 若仍有数据库记录引用该路径，拒绝操作。
- 操作只影响旧副本，不修改当前数据库记录。

## 四、平台持久访问

### iOS / macOS

- 选择长期存储目录时创建 security-scoped bookmark，写入 `UserDefaults`。
- 应用启动时解析 bookmark 并恢复安全作用域访问；过期时重建，解析失败时清除。
- macOS 增加 `com.apple.security.files.bookmarks.app-scope` entitlement（Debug/Release）。
- Dart 侧 `DirectoryPicker(persistAccess: true)` 传递 `persistent` 参数，并阻止 finalizer 提前停止访问。

### Android

- 使用 `flutter_saf` 的目录选择；已确认其调用 `takePersistableUriPermission`。
- 不使用 `directAccess: true`，避免把老目录复制到 cache。

## 五、涉及文件

| 文件 | 内容 |
| --- | --- |
| `lib/foundation/local.dart` | `LocalComic` 字段、schema 迁移、回填、`adoptExistingPath`、冲突副本删除/重命名、安全路径校验 |
| `lib/utils/import_comic.dart` | 恢复流程、目录扫描、去重、冲突收集、注册新增漫画 |
| `lib/pages/local_restore_conflicts_page.dart` | 冲突副本列表与批量操作 |
| `lib/pages/home_page.dart` | 恢复入口说明文案 |
| `lib/components/comic.dart` | 本地条目的作者/来源/语言/章节/页数展示 |
| `lib/utils/io.dart` | 持久目录选择与安全作用域保持 |
| `lib/foundation/comic_source/models.dart` | `ComicDetails.language`，供下载落库 |
| `lib/network/download.dart` | 下载完成时写入语言/页数 |
| `lib/utils/cbz.dart` | CBZ 导入导出 `LanguageISO`、页数 |
| `lib/utils/import_comic.dart`、`lib/foundation/local.dart` | 导入扫描语言/页数 |
| `ios/Runner/AppDelegate.swift`、`macos/Runner/AppDelegate.swift` | bookmark 创建/恢复 |
| `macos/Runner/*.entitlements` | app-scope bookmark 权限 |
| `assets/translation.json` | 新增中英文/繁体文案 |

## 六、自动化验证

- `dart analyze`（全部改动 Dart 文件）：通过，无新增问题。
- 本地库与恢复相关测试：22 项通过，1 项因 Windows 符号链接权限跳过。
- 新增恢复测试 6 项全部通过：
  - 零拷贝、只新增缺失漫画
  - 路径/标题/目录名去重
  - 重复执行幂等
  - 旧路径独有记录转绝对路径且不可误删
  - 冲突删除/重命名
  - 恢复后删除行为
  - 嵌套路径拒绝
- 本地条目 widget 测试 3 项通过：详细模式、简要模式、缺失字段与窄宽度。
- 全量 `flutter test`：302 通过，15 跳过，32 失败。失败集中在：
  - Windows 缺少 `avif_native` 的 `windows-x64` 原生产物导致的 AVIF 用例
  - Windows 符号链接权限与临时目录文件占用
  - 平台 WebView 用例
- 为运行测试曾临时在本地 manifest 中映射 Windows 占位产物，测试后已还原，未提交。

## 七、需要用户验证（待处理）

> 以下项目本环境无法完成，需在真机/CI 上验证后再视为完成。

- [ ] **[待用户验证] Android SAF 持久权限**：选择外部老目录 → 恢复 → 强制停止应用 → 重启 → 确认封面、章节图片仍可读，新下载仍写入该目录。
- [ ] **[待用户验证] Android 冲突处理**：删除/重命名旧副本后，当前副本不受影响；带「同时删除文件」删除恢复漫画时只删除新根内目录。
- [ ] **[待用户验证] iOS bookmark**：选择应用容器外的老目录 → 恢复 → 完全退出 → 重启 → 仍能读取；bookmark 过期后能重建。
- [ ] **[待用户验证] macOS bookmark**：Sandbox 下选择外部目录 → 恢复 → 重启 → 仍能读取，无 entitlement 报错。
- [ ] **[待用户验证] 旧路径唯一副本**：切换后该类漫画仍可打开，且删除时不会删除旧路径文件。
- [ ] **[待用户验证] 去重规则**：目录路径、标题、目录名三种命中任一均跳过；同名不同漫画是否符合预期需确认。
- [ ] **[待用户验证] 冲突批量操作**：大量冲突时全部删除/全部重命名、重名追加编号、失败项保留并提示。
- [ ] **[待用户验证] 列表 UI**：详细/简要模式、浅色/深色、窄窗口、超长作者/来源、语言缺失、tags 不被挤压。
- [ ] **[待用户验证] CI 全量回归**：在具备 AVIF 原生产物的 Linux/macOS 环境运行完整 `flutter test`。
- [ ] **[待用户验证] 发布流程**：如后续需要发布，先按 `doc/release-policy.md` 升版并记录，本迭代文档不代表发布结论。

## 八、已知限制

- 「设置 → 更改存储路径」仍保持原有复制语义并要求目标目录为空；零拷贝仅通过「恢复本地下载」入口。
- iOS/macOS 当前只维护一个全局存储 bookmark；若之后通过其它入口更改本地路径，需要重新执行恢复或补充 bookmark 更新逻辑。
- 老版本下载目录默认按「直接子目录 = 一部漫画」识别；多一层来源目录的结构不在本轮范围。
- `local.db` 不参与 App 数据备份；恢复依赖老下载目录本身。
