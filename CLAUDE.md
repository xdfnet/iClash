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
| `AppDelegate` | `iClashApp.swift` | 状态栏图标、菜单 Setup、事件分发、ProxyManagerDelegate |
| `MenuController` | `MenuController.swift` | 从 AppState 构建 NSMenu，通过 MenuControllerDelegate 回传操作 |
| `AppCoordinator` | `AppArchitecture.swift` | **统一编排**所有服务的启动/停止/切换/更新流程 |
| `AppState` | `AppArchitecture.swift` | `@Observable` 全局状态（SSOT），通过 `syncFromServices()` 同步 |
| `MihomoService` | `MihomoService.swift` | 内核进程生命周期（启动/停止/崩溃检测）、持有 NetworkServiceManager |
| `MihomoAPIClient` | `MihomoAPIClient.swift` | **新增** Mihomo REST API 调用（/proxies、/version），纯 struct，无状态 |
| `NetworkServiceManager` | `NetworkServiceManager.swift` | **新增** `networksetup` CLI 封装（系统代理设置/查询） |
| `ConfigManager` | `ConfigManager.swift` | 订阅下载（5MB 上限）、Base64解码、URI解析、运行时 YAML 生成；init 时引导 mihomo + Country.mmdb 到 config 目录 |
| `ProxyManager` | `ProxyManager.swift` | 代理列表缓存（2s 缓存有效期）、节点切换；支持 `ProxyManagerDelegate` 回调 |
| `AppSettings` | `AppSettings.swift` | UserDefaults 封装（订阅地址、更新时间） |

### 架构关键模式

**1. 协议层 + 测试替身（Protocol-based DI）**

所有服务都通过协议定义，使测试可注入 Fake 实现：
```
ServiceProtocols.swift → MihomoServiceProtocol, ConfigManagerProtocol,
                         ProxyManagerProtocol, AppSettingsProtocol,
                         KernelServiceControlling
```
`TestHelpers.swift` 提供 `FakeKernelService`、`FakeConfigManager`、`FakeProxyManager`、`FakeAppSettings`。

**2. MihomoService 拆分**

原 527 行 `MihomoService` 拆分为三个职责单一的组件：
- `MihomoService`：进程生命周期（启动/停止/崩溃检测/进程清理）
- `MihomoAPIClient`：HTTP API 调用（`fetchProxies`/`selectProxy`/`fetchKernelVersion`），无状态 struct
- `NetworkServiceManager`：`networksetup` CLI 封装（系统代理设置/查询）

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
              generateConfigContent()
                  ↓
              ├── URI列表? → 保存 providers.txt + 生成 proxy-providers 配置
              │                (Mihomo 原生解析 URI，app 不做转译)
              └── 完整 YAML → 直通保存
```

> **大小保护**：订阅内容经过 Content-Length 预检 + 实际接收校验 + Base64 解码后校验，三层保护拒绝 > 5MB 的订阅。

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
- GeoIP 数据库（`Country.mmdb`）

**启动时引导**：应用首次启动时，`ConfigManager.init()` 同时初始化两个资源到 `~/.config/iclash/`。之后 app 只使用 config 目录中的版本，Bundle 不再被读取。损坏时（mihomo 失去可执行权限、Country.mmdb 大小 < 1MB）自动从 Bundle 重新复制修复。

## 测试

- 框架：XCTest
- 模式：Fake 测试替身（protocol-based，手动注入到 `AppCoordinator` / `MenuController`）
- 总计 19 个测试，全部通过：
  - `ProxyGroupsParserTests`（10）：YAML proxy-groups 解析器，覆盖 inline/block/混合/注释/边界
  - `SubscriptionSizeLimitTests`（6）：订阅 5MB 大小校验
  - `MihomoServiceTests`（3）：内核路径解析（优先 config/引导/修复）
  - `AppSettingsTests`、`ProxyManagerTests`、`MenuControllerTests`：核心功能覆盖

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
├── providers.txt     # 订阅 URI 列表
├── mihomo            # 内核二进制（从 Bundle 引导，损坏时自动修复）
├── Country.mmdb      # GeoIP 数据库（从 Bundle 引导，大小 <1MB 时自动修复）
├── daemon.log        # 操作日志（1MB 滚动）
└── daemon.log.1      # 历史归档
```
```
~/Library/Preferences/David.iClash.plist   # UserDefaults（订阅地址）
```

## 代码风格

- `@MainActor` 注解所有 UI 层类
- 协议扩展提供默认参数值（如 `ConfigManagerProtocol.downloadIfChanged(url:)` 默认重试 3 次）
- 日志使用 `os.log.Logger`，category 按组件划分；关键操作同时写入 `DaemonLogger` 文件日志
- 错误类型统一使用 `LocalizedError` 枚举
- 不引入第三方依赖，全部使用系统框架
