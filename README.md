# iClash

基于 Mihomo 内核的 macOS 菜单栏代理客户端。

[![Version](https://img.shields.io/github/v/release/xdfnet/iClash?style=flat-square)](https://github.com/xdfnet/iClash/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15.0+-green.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## 项目概述

iClash 是一个面向 macOS 的轻量级菜单栏代理应用，围绕 Mihomo 内核提供节点订阅、代理切换和系统代理控制。应用以纯菜单栏形态运行，不占用 Dock 图标，适合日常驻留使用。

## 核心能力

- 纯菜单栏应用，界面简洁，常驻系统状态栏
- 应用启动后自动拉起 Mihomo 内核
- 内核运行状态与系统代理开关解耦
- 支持订阅地址拉取与运行时配置生成
- 支持多种代理 URI 格式，Mihomo proxy-providers 原生解析
- 支持代理组与节点切换
- 内置 Mihomo 二进制，无需额外安装内核

## 系统要求

- macOS 15.0 或更高版本
- Apple Silicon 或 Intel Mac

## 快速开始

1. 从 [Releases](https://github.com/xdfnet/iClash/releases/latest) 下载最新版 `iClash.app.zip`
2. 解压后拖入 `应用程序` 文件夹
3. 打开应用（菜单栏出现 iClash 图标）
4. 点击菜单栏 `iClash → 订阅设置`，填入你的订阅地址

首次启动会自动下载订阅并启动代理内核。`订阅设置` 窗口输入地址后点击 `保存` 即可。

## 订阅

订阅地址通过菜单栏 `iClash → 订阅设置` 修改，存储在 `UserDefaults` 中。无需手动编辑配置文件。

订阅内容下载后会自动识别并处理以下格式：

- Base64 编码订阅内容
- AnyTLS / Shadowsocks (SS) URI 列表
- 完整 Mihomo / Clash YAML 配置

当订阅返回的是 URI 列表时，应用会自动生成运行时 YAML 配置，并拼接默认 DNS、代理组和规则配置。

## 使用说明

1. 启动应用后，菜单栏会显示 iClash 图标
2. 应用会自动启动 Mihomo 内核，但不会自动开启系统代理
3. 点击"启动代理"后，系统流量会通过本地代理端口转发到内核（内核未运行时会自动先启动）
4. 点击"切换节点"可在代理组内选择节点
5. 菜单底部会显示运行错误信息（如有）
6. 点击"退出"会关闭系统代理、停止内核并退出应用

## 菜单项说明

| 菜单项 | 说明 |
| --- | --- |
| 启动/停止代理 | 切换系统代理（`127.0.0.1:7890`） |
| 切换节点 | 显示代理组及其节点，并支持切换 |
| 订阅设置 | 修改订阅地址 |
| 退出 | 停止内核并退出应用 |

## 运行机制

### 启动流程

```text
1. autoStart()
   ├─ 已有 config.yaml → 直接启动内核（秒启）
   └─ 无配置 → 下载订阅 → 生成 config.yaml → 启动内核
2. fetchKernelVersion() + refreshProxyList()    并行
3. syncFromServices()                           同步状态到菜单
```

### 节点切换流程

```text
1. 用户选择节点
2. proxyManager.selectProxy()        调用 Mihomo API 切换节点
```

### 代理开关流程

```text
1. 用户点击菜单"启动代理/停止代理"
2. setSystemProxy(enabled:)   设置或清除系统代理（HTTP + HTTPS + SOCKS）
3. 下次打开菜单时读取真实状态显示
```

app 不持久化代理开关状态，每次打开菜单时读取系统真实状态。退出应用时会自动关闭由本应用开启的系统代理，避免内核停止后流量指向死端口导致断网；开启系统代理前若内核未运行会自动拉起，拉起失败则不会开启代理。

## 源码构建

```bash
git clone https://github.com/xdfnet/iClash.git
cd iClash
make debug
```

依赖：Xcode 15+

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

## 资源更新

`scripts/update-resources.sh` 一键更新内置的 Mihomo 内核和 Country.mmdb 数据库。详见 [docs/upgrade-resources.md](docs/upgrade-resources.md)。

## 项目结构

```text
iClash/
├── Makefile                        # 常用构建与发布命令
├── scripts/
│   └── update-resources.sh         # 一键更新 mihomo + Country.mmdb
├── iClash.xcodeproj/               # Xcode 工程
├── docs/
│   ├── ARCHITECTURE.md             # 架构文档
│   └── upgrade-resources.md        # 资源更新指南
└── iClashSource/
    ├── iClashApp.swift             # 应用入口与 AppDelegate
    ├── AppSettings.swift           # 应用设置、环境变量与 UserDefaults
    ├── DefaultRules.swift          # 默认 DNS 与分流规则
    ├── MihomoService.swift         # 内核生命周期与系统代理控制
    ├── ConfigManager.swift         # 订阅下载、proxy-providers 生成
    ├── ProxyManager.swift          # 代理列表缓存与节点切换
    ├── MenuController.swift        # 菜单构建与交互
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

如需更新内核版本，可手动替换内置二进制文件。

## 许可证

本项目采用 `MIT` 许可证发布。

### 第三方组件

- `Mihomo`：来自 `MetaCubeX/mihomo`，其许可证信息以上游项目为准

发布或再分发本项目时，建议同时保留本项目许可证文本以及第三方组件的许可证与署名信息。

## 免责声明

本项目仅供学习与技术交流使用。请在使用前确认当地法律法规及网络使用政策，并自行承担相应责任。
