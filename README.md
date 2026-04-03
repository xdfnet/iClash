# iClash

基于 Mihomo 内核的 macOS 菜单栏代理客户端。

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Version](https://img.shields.io/badge/version-v1.0.3-brightgreen)
![License](https://img.shields.io/badge/License-MIT-green)

## 项目概述

iClash 是一个面向 macOS 的轻量级菜单栏代理应用，围绕 Mihomo 内核提供节点订阅、代理切换、系统代理控制和内核更新能力。应用以纯菜单栏形态运行，不占用 Dock 图标，适合日常驻留使用。

## 核心能力

- 纯菜单栏应用，界面简洁，常驻系统状态栏
- 应用启动后自动拉起 Mihomo 内核
- 内核运行状态与系统代理开关解耦
- 支持订阅地址拉取与运行时配置生成
- 支持 AnyTLS URI 列表自动转换为完整配置
- 支持代理组与节点切换
- 支持应用内检查并更新稳定版 Mihomo 内核
- 内置 Mihomo 二进制，无需额外安装内核

## 系统要求

- macOS 14.0 或更高版本
- Apple Silicon 或 Intel Mac
- Xcode 15+
- XcodeGen

## 快速开始

### 1. 获取源码

```bash
git clone https://github.com/xdfnet/iClash.git
cd iClash
```

### 2. 安装依赖

```bash
brew install xcodegen
```

### 3. 生成工程

```bash
xcodegen generate
```

### 4. 配置订阅地址

应用优先从系统环境变量 `ICLASH_SUBSCRIPTION_URL` 读取订阅地址。

终端启动场景：

```bash
export ICLASH_SUBSCRIPTION_URL="https://your-subscription-url"
```

Finder 或 Xcode 启动 GUI 应用场景：

```bash
launchctl setenv ICLASH_SUBSCRIPTION_URL "https://your-subscription-url"
```

如果未设置环境变量，应用会回退到本地保存的订阅地址（`UserDefaults`）。

### 5. 构建与运行

推荐使用项目内置的 `Makefile`：

```bash
make debug
```

也可以直接使用 `xcodebuild`：

```bash
xcodebuild -project iClash.xcodeproj -scheme iClash -configuration Debug -destination 'platform=macOS' build
```

## 配置与订阅

订阅内容下载后会自动识别并处理以下格式：

- Base64 编码订阅内容
- AnyTLS / SS / VMess / VLESS / Trojan / Hysteria / TUIC / WireGuard 等 URI 列表
- 完整 Mihomo / Clash YAML 配置

当订阅返回的是 URI 列表时，应用会自动生成运行时 YAML 配置，并拼接默认 DNS、代理组和规则配置。

## 使用说明

1. 启动应用后，菜单栏会显示 iClash 图标
2. 应用会自动启动 Mihomo 内核，但不会自动开启系统代理
3. 点击“启动代理”后，系统流量会通过本地 SOCKS 端口转发到内核
4. 点击“切换节点”可在代理组内选择节点
5. 点击“版本更新”可检查并更新内置内核
6. 点击“退出”会停止内核并退出应用

## 菜单项说明

| 菜单项 | 说明 |
| --- | --- |
| 启动代理 | 设置系统 SOCKS 代理到 `127.0.0.1:7890` |
| 停止代理 | 清除系统代理设置 |
| 切换节点 | 显示代理组及其节点，并支持切换 |
| 版本更新 | 显示当前内核版本与最新稳定版，并支持更新 |
| 退出 | 停止内核并退出应用 |

## 运行机制

### 启动流程

```text
1. ensureBaseConfigurationExists()   准备配置目录与基础资源
2. downloadAndValidateConfig()       首次启动时下载订阅配置
3. mihomoService.start()             启动 Mihomo 内核
4. updateStatusIcon()                更新状态栏图标
5. fetchKernelVersion()              获取内核版本
6. refreshProxyList()                刷新代理列表
7. buildMenu() / setMenu()           构建并应用菜单
```

### 节点切换流程

```text
1. 用户选择节点
2. proxyManager.selectProxy()        调用 Mihomo API 切换节点
3. buildMenu() / setMenu()           刷新菜单状态
```

### 代理开关流程

```text
1. 用户点击“启动代理/停止代理”
2. setSystemProxy(enabled:)          设置或清除系统代理
3. buildMenu() / setMenu()           刷新菜单状态
```

### 内核更新流程

```text
1. mihomoService.stop()              停止当前内核
2. KernelUpdater.checkForUpdate()    检查最新稳定版
3. KernelUpdater.getDownloadURL()    获取下载地址
4. KernelUpdater.downloadKernel()    下载新内核
5. KernelUpdater.installKernel()     替换内置二进制
6. mihomoService.start()             重新启动内核
```

## 开发命令

项目根目录内置 `Makefile`，用于本地开发和发布流程。

```bash
make help
make debug
make push MSG="your commit message"
```

说明：

- `make debug`：清理旧构建产物，构建 Debug 版本并直接启动应用
- `make push`：更新版本号、构建 Release、安装到 `/Applications`，然后提交并推送当前分支

## 手动更新内核

如需手动更新内核，可从 Mihomo Releases 下载对应平台版本：

- Apple Silicon: `mihomo-darwin-arm64-v{version}.gz`
- Intel Mac: `mihomo-darwin-amd64-v{version}.gz`

```bash
gunzip -c mihomo-darwin-arm64-v{version}.gz > iClashSource/Resources/mihomo
chmod +x iClashSource/Resources/mihomo
xcodegen generate
xcodebuild -project iClash.xcodeproj -scheme iClash -configuration Debug build
```

## 项目结构

```text
iClash/
├── Makefile                        # 常用构建与发布命令
├── project.yml                     # XcodeGen 配置
├── iClash.entitlements             # 沙盒权限
├── iClash.xcodeproj/               # Xcode 工程
└── iClashSource/
    ├── iClashApp.swift             # 应用入口与 AppDelegate
    ├── AppSettings.swift           # 应用设置、环境变量与 UserDefaults
    ├── DefaultRules.swift          # 默认 DNS 与分流规则
    ├── MihomoService.swift         # 内核生命周期与系统代理控制
    ├── ConfigManager.swift         # 订阅下载、配置解析与运行时配置生成
    ├── ProxyManager.swift          # 代理列表缓存与节点切换
    ├── StatusBarController.swift   # 状态栏图标与菜单挂载
    ├── MenuController.swift        # 菜单构建与交互
    ├── KernelUpdater.swift         # 内核版本检查与更新
    ├── Resources/
    │   ├── Assets.xcassets/        # 图标资源
    │   ├── Country.mmdb            # GeoIP 数据库
    │   └── mihomo                  # 内置 Mihomo 二进制
    └── Supporting/
        └── Info.plist
```

## 内核来源

本项目内置的代理内核来自 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)。

- 上游仓库：`https://github.com/MetaCubeX/mihomo`
- 发布地址：`https://github.com/MetaCubeX/mihomo/releases/latest`
- 仓库内置路径：`iClashSource/Resources/mihomo`

如需更新内核版本，可使用应用内“版本更新”功能，或手动替换内置二进制文件。

## 许可证

本项目采用 `MIT` 许可证发布。

### 第三方组件

- `Mihomo`：来自 `MetaCubeX/mihomo`，其许可证信息以上游项目为准

发布或再分发本项目时，建议同时保留本项目许可证文本以及第三方组件的许可证与署名信息。

## 免责声明

本项目仅供学习与技术交流使用。请在使用前确认当地法律法规及网络使用政策，并自行承担相应责任。
