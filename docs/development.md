# 开发与构建

本文面向希望自行编译或参与开发的用户。下载安装和日常使用请参阅 [README](../README.md)。

## 从源码构建

如需自行编译，在仓库根目录执行：

```bash
./build.sh
```

生成产物：`build/输入法锁定.app`

构建脚本会编译 arm64 和 x86_64 并合并为通用二进制，验证实际架构及签名；任何一个架构失败都会中止，不会降级为单架构后仍标为 universal。

如果当前 Command Line Tools 缺少 Intel 兼容库，请选择带完整兼容库的 Xcode 工具链后再构建 universal；仅在本机 Apple Silicon 使用时，可执行 `bash build.sh --target arm64`。

已安装完整 Xcode 时，可以仅对本次构建指定工具链，无需修改系统的 `xcode-select` 设置：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build_dmg.sh 0.0.8 universal
```

此方式使用同一套 Xcode 中的编译器、SDK 和兼容库，并保留 macOS 12 的最低系统要求。

打包 DMG：

```bash
./scripts/build_dmg.sh
```

发布时以 `Resources/Info.plist` 为版本来源，Git tag 和打包参数必须与其一致。CI（`.github/workflows/ci.yml`）会在推送到 `main` 和 PR 时自动运行回归测试并构建 universal 包；发布流程（`.github/workflows/release.yml`）仅编译两个架构各一次，复用产物生成三个安装包与 `SHA256SUMS.txt`，先上传为草稿，全部上传成功后公开，重跑会跳过已公开的 release，不覆盖其附件。

一次构建并打包全部架构：

```bash
bash build.sh --target all
for target in universal arm64 x86_64; do
  bash scripts/build_dmg.sh 0.0.8 "$target" --skip-build
done
```

其中 `0.0.8` 应与当前 `Info.plist` 版本保持一致。`--skip-build` 读取 `build/<架构>/输入法锁定.app`，仍会检查版本、架构和签名。

## 验证

```bash
bash scripts/test.sh
```

回归测试使用隔离的偏好设置、输入法系统替身、前台应用替身、键盘/鼠标活跃替身和网络响应，不切换系统输入法。覆盖版本比较、锁定状态机、分布式通知、休眠唤醒与锁屏解锁、闲置去重、打字/修饰键/鼠标按下严格防打断、父容器过滤与升级、退避保护、按应用暂停、单实例保护、旧配置迁移、菜单交互、图标透明度以及构建与发布脚本失败路径。

本机可运行 `IMELOCKER_UI_TESTS=1 bash scripts/test.sh`，额外验证真实 `NSAlert` 模态循环中的异步更新；测试会短暂显示并自动关闭一个测试窗口。

发布前仍应在 macOS 12 和 Intel 真机上检查菜单、输入法切换、密码框暂停恢复、应用例外及登录启动行为。

## 工作原理

应用通过 macOS Carbon 框架的 TIS（Text Input Source）API 获取输入法，切入中文/第三方输入法时优先通过当前键盘焦点进程的 TSM 端口（`com.apple.tsm.portname`）发起切换（失败自动回退 `TISSelectInputSource`），在以下时机尝试恢复目标输入法：

1. **系统通知** — 通过分布式通知中心监听 `kTISNotifySelectedKeyboardInputSourceChanged` 与 `kTISNotifyEnabledKeyboardInputSourcesChanged`
2. **应用切换** — 监听 `NSWorkspace.didActivateApplicationNotification`，前台应用变化时检查
3. **休眠唤醒与解锁** — 监听 `didWakeNotification`、`screensDidWakeNotification` 和 `sessionDidBecomeActiveNotification`，唤醒或锁屏解锁后立即恢复
4. **周期性兜底检查** — 每 5 秒轻量检查一次（闲置已锁定时跳过列表重查与冗余 UI 刷新；菜单打开时主动刷新列表）

保护机制：
- 连续打字（`keyDown` / `keyUp` / `flagsChanged`）、按住修饰键或按下鼠标键期间严格顺延自动切换，不打断当前输入；
- 过滤 `ModeEnabled` 冗余父容器并自动升级旧配置，避免父子 ID 不一致导致的反复重切；
- 当前处于 `Secure Input` 场景（密码框、系统授权窗口等）或前台应用位于例外列表时，暂停强制切换；
- 切换后具备 `300ms` 冷却期，连续切换失败或被高频弹回时自动启用指数退避（最高 2 秒）；
- 启动时执行单实例保护（重启流程通过 `--relaunch` 放行），并自动迁移旧版 `com.example.InputSourceLock` 偏好设置。

## 重新生成应用图标

主图标母版保存在 `Resources/AppIcon.png`（1024×1024 透明圆角 RGBA PNG）。更新母版后，使用 Python/Pillow 重新封装为全套 11 规格的 `Resources/AppIcon.icns`（`ic10` 块与 `Resources/AppIcon.png` 逐字节一致，16px/32px 自动做轻量锐化）：

```bash
python3 scripts/generate_icon.py
swift tests/IconTests.swift
```

圆角透明留白与所有 11 个 ICNS 变体的完整性校验已纳入 `scripts/test.sh`。
