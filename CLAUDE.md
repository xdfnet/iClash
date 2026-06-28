# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

iClash 是一个基于 Mihomo 内核的 macOS 菜单栏代理客户端，支持节点订阅、代理切换和系统代理控制。

## 构建与运行

```bash
cd /Users/admin/iCode/iClash

# 调试构建并启动
make debug

# Release 构建并安装到 /Applications
make install

# 打包 zip
make package

# 完整发布流程（递增版本号→构建→安装→打包→push→GitHub Release）
make push MSG="提交信息"

# 卸载应用及运行时数据
make uninstall
```

## 运行测试

```bash
# 全部测试
xcodebuild -project iClash.xcodeproj -scheme iClash -destination 'platform=macOS' test

# 单文件测试（需先 Build once）
xcodebuild -project iClash.xcodeproj -scheme iClash -destination 'platform=macOS' test -only-testing:iClashTests/ConfigManagerTests
```

## 项目配置

| 配置项 | 值 |
|--------|-----|
| 最低 macOS | 15.0 |
| Swift 版本 | 6.2 |
| Xcode 版本 | 16.0 |
| Bundle ID | David.iClash |
| 签名 | ad-hoc |

## 架构

### 分层架构概览

```
┌────────────────────────────────────────────────────┐
│  AppDelegate             状态栏 + 菜单 + 事件分发    │
│  ┌────────────────────────────────────────────────┐ │
│  │  MenuController       菜单构建（读 AppState）    │ │
│  │  SubscriptionSettingsWindow  SwiftUI 订阅窗口    │ │
│  └──────────┬─────────────────────────────────────┘ │
│             │ 委托                                  │
│  ┌──────────▼─────────────────────────────────────┐ │
│  │  AppCoordinator        统一编排服务生命周期      │ │
│  └──────────┬─────────────────────────────────────┘ │
│             │ 协议接口                              │
│  ┌──────────▼─────────────────────────────────────┐ │
│  │  Protocol Layer  (MihomoServiceProtocol, …)    │ │
│  │  ┌──────────┐┌───────────┐┌───────────────┐   │ │
│  │  │MihomoServ.││ConfigMgr  ││ProxyManager   │   │ │
│  │  └──────────┘└───────────┘└───────────────┘   │ │
│  │  ┌───────────┐                                │ │
│  │  │AppSettings│ (UserDefaults)                 │ │
│  │  └───────────┘                                │ │
│  └───────────────────────────────────────────────┘ │
│                                                     │
│  AppState (Observable) ← syncFromServices()         │
└─────────────────────────────────────────────────────┘
```

### 核心组件

| 组件 | 文件 | 职责 |
|------|------|------|
| `iClashApp` | `iClashApp.swift` | SwiftUI App 入口 + `@main` |
| `AppDelegate` | `iClashApp.swift` | 状态栏图标、菜单 Setup、事件分发 |
| `MenuController` | `MenuController.swift` | 从 AppState 构建 NSMenu，通过 MenuControllerDelegate 回传操作 |
| `AppCoordinator` | `AppArchitecture.swift` | **统一编排**所有服务的启动/停止/切换/更新流程 |
| `AppState` | `AppArchitecture.swift` | `@Observable` 全局状态（SSOT），通过 `syncFromServices()` 同步 |
| `MihomoService` | `MihomoService.swift` | 内核生命周期（启动/停止） + 系统 SOCKS 代理控制 + 内核 REST API 调用 |
| `ConfigManager` | `ConfigManager.swift` | 订阅下载、Base64解码、URI解析、运行时 YAML 生成 |
| `ProxyManager` | `ProxyManager.swift` | 代理列表缓存（2s 缓存有效期）、节点切换 |
| `AppSettings` | `AppSettings.swift` | UserDefaults 封装（订阅地址、更新时间） |

### 已删除的文件

`KernelUpdater.swift` — 内核更新功能已移除。`KernelUpdateCoordinatorTests.swift`、`KernelUpdaterTests.swift` 同批删除。

### 架构关键模式

**1. 协议层 + 测试替身（Protocol-based DI）**

所有服务都通过协议定义，使测试可注入 Fake 实现：
```
ServiceProtocols.swift → MihomoServiceProtocol, ConfigManagerProtocol,
                         ProxyManagerProtocol, AppSettingsProtocol,
                         KernelServiceControlling
```
`TestHelpers.swift` 提供 `FakeKernelService`、`FakeConfigManager`、`FakeProxyManager`、`FakeAppSettings`。

**2. AppCoordinator 编排模式**

所有多服务协作逻辑集中在 `AppCoordinator`，避免在外层 AppDelegate 中散布启动/停止/订阅变更逻辑。外部只需调 `coordinator.applySubscription(url:)`。

**3. 通知解耦**

```
Notification.Name:
  .openSubscriptionSettings    → 菜单项触发打开设置窗口
  .subscriptionSettingsDidSave → 设置窗口保存后通知 AppDelegate 重新订阅
  .mihomoCrashed               → 内核意外退出后弹错误提示
```

### 订阅内容处理流水线

```
原始订阅 URL  →  downloadSubscriptionContent()
                  ↓
              base64Decode()        // 自动检测并解码 Base64
                  ↓
              normalizeSubscriptionContent()
                  ↓
              ├── URI列表? → 保存 providers.txt + 生成 proxy-providers 配置
              │                (Mihomo 原生解析 URI，app 不做转译)
              └── 完整 YAML → 直通保存
```

### 内核通信（REST API）

Mihomo 暴露 HTTP API `127.0.0.1:9090`：
- `GET /proxies` → 获取所有代理/代理组
- `PUT /proxies/{group}` → 切换节点（JSON body: `{"name": "..."}`）
- `GET /version` → 获取内核版本

### 代理支持

- 所有 URI 格式（anytls://, ss://, vmess://, trojan://, vless://, hysteria2://, tuic:// 等）由 Mihomo `proxy-providers` 原生解析
- 订阅 → 保存为 `providers.txt`，生成 proxy-providers 配置
- 默认代理组：BoostNet、自动选择、故障转移

### 内置资源

- Mihomo 内核二进制（`iClashSource/Resources/mihomo`）
- GeoIP 数据库（`Country.mmdb`，通过符号链接到 `~/.config/iclash/`）

## 测试

- 框架：XCTest
- 模式：Fake 测试替身（protocol-based，手动注入到 `AppCoordinator` / `MenuController`）
- 单测覆盖：`AppSettingsTests`（UserDefaults 读写验证）、`ConfigManagerTests`（proxy-providers 生成）、`MenuControllerTests`（菜单构建状态）、`MihomoServiceTests`（内核文件解析）、`ProxyManagerTests`（缓存/重置逻辑）

> **注意**：当前测试主要覆盖纯逻辑层（配置解析、菜单构建），核心集成测试（AppCoordinator 编排流程）尚未覆盖。

## 构建说明

**XcodeGen 已弃用** — 项目不再使用 `project.yml`，直接通过 `iClash.xcodeproj` 构建。`make debug` 和 `make install` 是推荐的构建方式。

发布流程 `make push` 会自动：
1. 递增 `MARKETING_VERSION` 的补丁号
2. 更新 README.md 中的 Release URL
3. 构建 Release → 安装到 `/Applications`
4. 打包 zip → `git add; git commit; git push`
5. 调用 `gh release create` 创建 GitHub Release

## 数据存储

```
~/.config/iclash/
├── config.yaml       # 运行时生成的 mihomo 配置
├── run               # 内核运行时文件
└── Country.mmdb      # GeoIP 数据库（符号链接到 Bundle 内资源）
```
```
~/Library/Preferences/David.iClash.plist   # UserDefaults（订阅地址）
```

## 代码风格

- `@MainActor` 注解所有 UI 层类
- 协议扩展提供默认参数值（如 `ConfigManagerProtocol.downloadAndValidateConfig(url:)` 默认重试 3 次）
- 日志使用 `os.log.Logger`，category 按组件划分
- 错误类型统一使用 `LocalizedError` 枚举
- 不引入第三方依赖，全部使用系统框架
