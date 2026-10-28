# Venera Prime — Claude Code 工作说明

@AGENTS.md

## 分支与发布

- 较大改动提交到本地分支 `CC_vibe_coding`，不要直接提交到 `master`，除非用户明确要求。
- 准备版本、编写 Release 说明或执行发布前，先阅读 `doc/release-policy.md`；不得擅自升版或更改既有 Release。

## 本地测试

- 单元/组件测试：`flutter test --no-pub --concurrency=2`
- 单个文件：`flutter test --no-pub test/foo_test.dart`
- 静态分析：`flutter analyze --no-pub`
- 固定入口（Git Bash）：`bash tool/dev_test.sh [测试文件...]`；PowerShell 可用 `tool/dev_test.ps1`，但需当前执行策略允许运行本地脚本。两者都会设置 GitHub SSH 重写，再执行 `pub get` 和测试。
- 集成测试需要设备：`flutter test integration_test/foo_test.dart -d <device-id>`；Windows 桌面测试需开启开发者模式。

## 环境注意事项

- 固定 Flutter 3.41.4 / Dart 3.11.1；不要修改 `pubspec.yaml` 的 SDK 约束。
- Windows 下使用 `python`；`python3` 可能是不可用的 Store 占位符。
- 本机 GitHub HTTPS 不稳定：`.claude/settings.json` 和 `tool/dev_test.ps1` 只用临时 `GIT_CONFIG_*` 将 `https://github.com/` 重写为 SSH，不修改全局 `~/.gitconfig`。
- AVIF native asset 缓存位于 `.dart_tool/hooks_runner` 与 `build/native_assets/windows`。如果 Windows 目录里出现 Android `.so`，删除这两个目录并重跑 `test/avif_codec_test.dart`。
- Windows 未开启开发者模式时，创建 symlink 的测试会因权限 1314 失败；部分测试删除临时目录时也可能因文件仍被占用而失败。
- Android 构建需要 JDK 17、SDK platform 36、NDK 28.0.13004108；当前本机未配置，不影响单元测试。
