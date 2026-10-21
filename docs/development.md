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
  bash scripts/build_dmg.sh 0.0.6 universal
```

此方式使用同一套 Xcode 中的编译器、SDK 和兼容库，并保留 macOS 12 的最低系统要求。

打包 DMG：

```bash
./scripts/build_dmg.sh
```

发布时以 `Resources/Info.plist` 为版本来源，Git tag 和打包参数必须与其一致。CI 仅编译两个架构各一次，再复用产物生成三个安装包；新发布先上传为草稿，全部上传成功后公开，重跑会跳过已公开的 release，不覆盖其附件。

一次构建并打包全部架构：

```bash
bash build.sh --target all
for target in universal arm64 x86_64; do
  bash scripts/build_dmg.sh 0.0.6 "$target" --skip-build
done
```

其中 `0.0.6` 应与当前 `Info.plist` 版本保持一致。`--skip-build` 读取 `build/<架构>/输入法锁定.app`，仍会检查版本、架构和签名。

## 验证

```bash
bash scripts/test.sh
```

回归测试使用隔离的偏好设置、输入法系统替身和网络响应，不切换系统输入法。构建与发布测试在临时目录中模拟工具失败，覆盖缺失架构、签名失败、非法参数、版本不一致、编译复用，以及已公开版本保护和草稿上传失败。

本机可运行 `IMELOCKER_UI_TESTS=1 bash scripts/test.sh`，额外验证真实 `NSAlert` 模态循环中的异步更新；测试会短暂显示并自动关闭一个测试窗口。

发布前仍应在 macOS 12 和 Intel 真机上检查菜单、输入法切换、密码框暂停恢复及登录启动行为。

## 工作原理

应用通过 macOS Carbon 框架的 TIS（Text Input Source）API 获取和切换输入法，在以下时机尝试恢复目标输入法：

1. **系统通知** — 通过分布式通知中心监听 `kTISNotifySelectedKeyboardInputSourceChanged`，输入法被切换时立即响应
2. **应用切换** — 监听 `NSWorkspace.didActivateApplicationNotification`，前台应用变化时检查
3. **周期性检查** — 每 5 秒检查一次，同时刷新输入法列表，兜底防止通知遗漏

如果当前处于 `Secure Input` 场景（密码输入框、系统授权窗口等），应用会暂停强制切换，避免反复抢输入法。


## 重新生成应用图标

图标由 `scripts/generate_icon.py` 中的 SVG 几何图形生成。使用 Node.js 的 `sharp` 直接渲染透明 SVG，再由 Python/Pillow 缩放并封装为 ICNS；Quick Look 缩略图会填充白色背景，不适用于此流程。

首次准备图标工具（应用本身无需这些依赖）：

```bash
mkdir -p build
python3 -m venv build/icon-venv
build/icon-venv/bin/pip install Pillow
npm install --prefix build/icon-tools sharp
```

重新生成并验证：

```bash
build/icon-venv/bin/python scripts/generate_icon.py
swift tests/IconTests.swift
```

生成器同时更新 `Resources/AppIcon.icns` 和 README 使用的 `Resources/AppIcon.png`。圆角和透明留白直接保存在图像中，适用于使用传统 ICNS 的旧版 macOS。透明度回归检查已纳入 `scripts/test.sh`。

图标包含 11 个 ICNS 变体，覆盖标准及 Retina 尺寸。16px、32px 使用单独绘制的简化版：减少键帽数量、加粗锁柄并去掉锁孔和投影，以提高小尺寸辨识度。
