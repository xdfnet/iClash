# iClash 架构文档

## 概述

iClash 是一个纯菜单栏 macOS 代理客户端。应用本身只负责编排，真正的代理能力由内置的 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核提供。

```
┌─────────────────────────────────────────┐
│              iClash (UI)                │
│  MenuController  ←→  AppCoordinator      │
│                          │              │
│   ┌──────────────────────┼──────────┐   │
│   │    Service Layer       │          │   │
│   │  ConfigManager         │          │   │
│   │  MihomoService         │          │   │
│   │    ├ MihomoAPIClient  │          │   │
│   │    └ NetworkServiceMgr │          │   │
│   │  ProxyManager          │          │   │
│   │  AppSettings           │          │   │
│   └──────────────────────┼──────────┘   │
│                          │              │
└──────────────────────────┼──────────────┘
                           │ HTTP API :9090
                    ┌──────┴──────┐
                    │  Mihomo     │
                    │  (Go 二进制) │
                    │  mixed-port │
                    │  :7890      │
                    └─────────────┘
                           │ SOCKS5
                    ┌──────┴──────┐
                    │  系统代理    │
                    │ networksetup│
                    └─────────────┘
```

## 核心组件

### 1. 应用层

| 组件 | 职责 | 文件 |
|------|------|------|
| `iClashApp` | SwiftUI App 入口，声明 Settings Scene | iClashApp.swift |
| `AppDelegate` | 菜单栏图标管理、通知分发、MenuControllerDelegate、ProxyManagerDelegate | iClashApp.swift |
| `AppCoordinator` | 服务编排：启动/停止/订阅/代理切换 | AppArchitecture.swift |
| `AppState` | 全局单例状态，@Observable，SSOT | AppArchitecture.swift |
| `MenuController` | NSMenu 构建、NSMenuDelegate | MenuController.swift |

### 2. 服务层

所有服务通过 Protocol 接口定义，实现类通过依赖注入注入：

| 协议 | 实现 | 职责 |
|------|------|------|
| `MihomoServiceProtocol` | `MihomoService` | 内核进程生命周期管理 |
| `KernelServiceControlling` | `MihomoService` | 系统代理控制（由 `NetworkServiceManager` 实现） |
| `MihomoAPIClient` | （struct，通过 `MihomoService` 调用） | Mihomo REST API 调用（/proxies, /version） |
| `NetworkServiceManager` | （singleton，被 `MihomoService` 持有） | `networksetup` CLI 封装（系统代理设置/查询） |
| `ConfigManagerProtocol` | `ConfigManager` | 订阅下载、格式识别、运行时配置生成 |
| `ProxyManagerProtocol` | `ProxyManager` | 代理列表缓存（2s）、节点选择；支持 delegate 回调 |
| `AppSettingsProtocol` | `AppSettings` | UserDefaults 存取 |

### 3. 数据模型

| 模型 | 用途 |
|------|------|
| `AppState` | 全局响应式状态（@Observable） |
| `AppSettings` | 持久化设置（UserDefaults） |
| `DefaultRules` | 默认 DNS、代理组、分流规则模板 |
| `ProxyInfo` / `ProxiesResponse` | Mihomo API /proxies 响应 |

## 数据流

### 订阅 → 内核启动

```
应用启动
  └─ ConfigManager.init()                  ← 同时初始化 Country.mmdb + mihomo
       ├─ ensureGeoIPExists()            → ~/.config/iclash/Country.mmdb
       └─ ensureKernelExists()            → ~/.config/iclash/mihomo

用户输入订阅 URL
       │
       ▼
saveSettings() → UserDefaults
       │
       ▼ post(.subscriptionSettingsDidSave)
AppDelegate.subscriptionSettingsDidSave()
       │
       ▼
AppCoordinator.applySubscription(url)
  ├─ downloadIfChanged(url)              下载+识别格式（5MB 上限）
  │    ├─ Base64? → 解码
  │    ├─ URI列表? → 保存 providers.txt，生成 proxy-providers 配置
  │    └─ YAML? → 直接使用
  │    └─ 写入 ~/.config/iclash/config.yaml
  ├─ mihomo.start()
  │    ├─ cleanupStaleProcesses()        lsof 清理残留
  │    ├─ prepareRuntimeConfigFile()    文件已存在则跳过
  │    ├─ process.run()                 启动内核进程
  │    └─ API 探测 (/version) 确认就绪
  ├─ fetchKernelVersion() + refreshProxyList()  并行
  └─ syncFromServices()                  同步 AppState
```

### 菜单打开 → 状态刷新

```
menuWillOpen()
  ├─ isSystemProxyEnabled()              实时查询 (NetworkServiceManager)
  ├─ isRunning                          读 MihomoService 属性
  ├─ rebuildMenu()                      用最新状态构建菜单
  └─ Task { proxy.refreshProxyList() }   后台刷新代理列表
       └─ 完成时 → ProxyManagerDelegate → AppDelegate
            └─ syncUI()                  重建菜单（节点列表更新）
```

### 代理切换

```
用户点击节点 → selectProxy(name, group)
  └─ MihomoAPIClient.selectProxy()      PUT /proxies/{group}
  └─ appState.currentSelections 更新
```

## 状态管理

`AppState` 是唯一的全局状态容器，所有 UI 从此读取：

```swift
@Observable
@MainActor
final class AppState {
    // 内核状态
    var isRunning: Bool
    var isProxyEnabled: Bool
    var kernelVersion: String

    // 代理组
    var proxyGroups: [(name: String, proxies: [String])]
    var currentSelections: [String: String]
    var isLoadingProxies: Bool

    // 错误
    var lastError: String?

    // 订阅
    var hasSubscriptionURL: Bool
}
```

状态同步路径：
- **订阅变更 → 完整同步**：`syncFromServices()` 一次同步所有字段
- **菜单打开 → 部分同步**：只查 `isProxyEnabled` + `isRunning`（实时性要求高）
- **代理切换 → 局部更新**：只写 `currentSelections`
- **后台刷新完成 → 菜单重建**：`ProxyManagerDelegate.proxyManagerDidRefresh()` 回调触发

## 服务协议层

所有核心服务背后都有 Protocol，方便测试注入：

```swift
protocol MihomoServiceProtocol: KernelServiceControlling { ... }
protocol ConfigManagerProtocol { ... }
protocol ProxyManagerProtocol { ... }
protocol AppSettingsProtocol { ... }
protocol KernelServiceControlling { ... }
```

`AppCoordinator` 通过协议引用服务，默认实现在 `init` 参数中提供：

```swift
init(
    mihomo: any MihomoServiceProtocol = MihomoService.shared,
    config: any ConfigManagerProtocol = ConfigManager.shared,
    proxy: any ProxyManagerProtocol = ProxyManager.shared,
    settings: any AppSettingsProtocol = AppSettings.shared,
    appState: AppState = .shared
)
```

`ProxyManager` 同样接受构造器注入：

```swift
init(mihomo: any MihomoServiceProtocol = MihomoService.shared,
     config: any ConfigManagerProtocol = ConfigManager.shared)
```

## 并发模型

所有 UI 和服务代码运行在 `@MainActor` 上，消除数据竞争：

- `AppState` → `@MainActor`
- `MihomoService` → `@MainActor`
- `MihomoAPIClient` → `@MainActor` (struct)
- `NetworkServiceManager` → `@MainActor`
- `AppCoordinator` → `@MainActor`
- `MenuController` → `@MainActor`

进程管理例外：`Process.terminationHandler` 在后台线程触发，但通过 `Task { @MainActor ... }` 切回主线程。

## 资源管理

```
Bundle (iClash.app)
├── Contents/Resources/mihomo          ← 内核二进制（启动时复制到 config）
├── Contents/Resources/Country.mmdb      ← GeoIP 数据库（启动时复制到 config）
└── Contents/Resources/Assets.xcassets

~/.config/iclash/                        ← 运行时目录
├── mihomo                              ← 内核二进制（从 Bundle 引导）
├── Country.mmdb                        ← GeoIP 数据库（从 Bundle 引导，>1MB 损坏时自动修复）
├── config.yaml                          ← 运行时配置（proxy-providers 框架）
├── providers.txt                        ← 订阅 URI 列表（Mihomo 原生解析）
└── daemon.log                          ← 操作日志（1MB 滚动，保留一个归档）
```

启动时 `ConfigManager.init()` 同时初始化两个资源文件：
- `ensureKernelExists()` — mihomo 从 Bundle 复制到 config，损坏时自动从 Bundle 修复
- `ensureGeoIPExists()` — Country.mmdb 从 Bundle 复制到 config，大小 < 1MB 时自动修复

## 系统代理控制

通过 `NetworkServiceManager` 封装 `/usr/sbin/networksetup` CLI：

| 操作 | 命令 |
|------|------|
| 启用 | `-setwebproxy` + `-setwebproxystate` + `-setsecurewebproxy` + `-setsocksfirewallproxy` |
| 禁用 | `-setwebproxystate off` + `-setsecurewebproxystate off` + `-setsocksfirewallproxystate off` |
| 查询 | `-getwebproxy` |

- 自动枚举所有活跃网络服务（Wi-Fi、Ethernet 等）
- app 不管理代理状态，仅菜单点击时开/关，打开菜单时读取真实状态

## 崩溃恢复

```
进程终止 → terminationHandler
  ├─ .exit (正常停止) → 静默，不触发重启
  └─ .uncaughtSignal (崩溃)
       └─ post(.mihomoCrashed)    通知自动重启内核
```

## 配置格式支持

| 格式 | 检测方式 | 处理 |
|------|----------|------|
| Base64 编码 | 尝试 Base64 解码 | 解码后重新识别 |
| URI 列表 | 所有非空行均为 `scheme://...` 格式 | 保存为 `providers.txt`，生成 proxy-providers 配置（Mihomo 原生解析） |
| YAML 配置 | 包含 `proxies:` 或 `rules:` | 直接使用 |

URI 列表无需 app 解析，由 Mihomo `proxy-providers` 原生处理，支持 all supported protocols (anytls, ss, vmess, trojan, vless, hysteria2, tuic, etc.)

## 订阅大小保护

订阅内容经过三层大小校验：
1. 响应头 `Content-Length` 预检（超过 5 MB 直接拒绝）
2. 实际接收字节数校验
3. Base64 解码后字节数校验

## 日志系统

`DaemonLogger` 同时输出到：
- `~/.config/iclash/daemon.log`（文件日志，1MB 自动滚动，保留 `daemon.log.1`）
- macOS Unified Logging（通过 `OSLog`，可用 Console.app 或 `log show` 查看）

```bash
# 实时查看日志
log stream --predicate 'subsystem == "com.iclash.macos"' --style syslog

# 查看历史日志
log show --predicate 'subsystem == "com.iclash.macos"' --style syslog --last 1h
```
