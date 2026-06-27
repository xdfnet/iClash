# iClash 架构文档

## 概述

iClash 是一个纯菜单栏 macOS 代理客户端。应用本身只负责编排，真正的代理能力由内置的 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核提供。

```
┌─────────────────────────────────────────┐
│              iClash (UI)                │
│  MenuController  ←→  AppCoordinator    │
│                          │              │
│   ┌──────────────────────┼──────────┐   │
│   │    Service Layer      │          │   │
│   │  ConfigManager  MihomoService    │   │
│   │  ProxyManager  AppSettings       │   │
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
| `AppDelegate` | 菜单栏图标管理、通知分发、MenuControllerDelegate | iClashApp.swift |
| `AppCoordinator` | 服务编排：启动/停止/订阅/代理切换 | AppArchitecture.swift |
| `AppState` | 全局单例状态，@Observable，SSOT | AppArchitecture.swift |
| `MenuController` | NSMenu 构建、NSMenuDelegate | MenuController.swift |

### 2. 服务层

所有服务通过 Protocol 接口定义，实现类通过依赖注入注入：

| 协议 | 实现 | 职责 |
|------|------|------|
| `MihomoServiceProtocol` | `MihomoService` | 内核进程生命周期、系统代理控制、API 通信 |
| `ConfigManagerProtocol` | `ConfigManager` | 订阅下载、内容识别、运行时配置生成 |
| `ProxyManagerProtocol` | `ProxyManager` | 代理列表缓存、节点选择 |
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
  ├─ downloadAndValidateConfig(url)    下载+识别格式
  │    ├─ Base64? → 解码
  │    ├─ URI列表? → 生成完整 YAML 配置
  │    └─ 已有 YAML? → 直接使用
  │    └─ 写入 ~/.config/iclash/config.yaml
  ├─ mihomo.start()
  │    ├─ cleanupStaleProcesses()      lsof 清理残留
  │    ├─ prepareRuntimeConfigFile()   文件已存在则跳过
  │    ├─ process.run()                启动内核进程
  │    └─ 轮询 3s 确认进程存活
  ├─ setSystemProxy(true)              恢复系统代理
  ├─ fetchKernelVersion() + refreshProxyList()  并行
  └─ syncFromServices()                同步 AppState
```

### 菜单打开 → 状态刷新

```
menuWillOpen()
  ├─ isSystemProxyEnabled()            实时查询 (networksetup)
  ├─ isRunning                         读 MihomoService 属性
  ├─ rebuildMenu()                     用最新状态构建菜单
  └─ Task { refreshProxyList() }       后台刷新代理列表
```

### 代理切换

```
用户点击节点 → selectProxy(name, group)
  └─ PUT /proxies/{group}  {name}     Mihomo API
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

## 并发模型

所有 UI 和服务代码运行在 `@MainActor` 上，消除数据竞争：

- `AppState` → `@MainActor`
- `MihomoService` → `@MainActor`
- `AppCoordinator` → `@MainActor`
- `MenuController` → `@MainActor`

进程管理例外：`Process.terminationHandler` 在后台线程触发，但通过 `Task { @MainActor ... }` 切回主线程。

## 资源管理

```
Bundle (iClash.app)
├── Contents/Resources/mihomo          ← 可执行文件，直接运行
├── Contents/Resources/Country.mmdb    ← GeoIP 数据库
└── Contents/Resources/Assets.xcassets

~/.config/iclash/                      ← 运行时目录
├── config.yaml                        ← 运行时配置（订阅生成）
├── Country.mmdb ──符号链接──→ Bundle   ← 通过软链访问，不占额外空间
└── run/                               ← mihomo 运行时文件
```

- `mihomo` 二进制直接从 Bundle 路径启动
- `Country.mmdb` 通过符号链接从 Bundle 引用，首次启动时在 `~/.config/iclash/` 下创建
- 检测到符号链接断裂（Bundle 路径变更/App 重装）时自动重建

## 系统代理控制

通过 `/usr/sbin/networksetup` CLI 控制 macOS 系统代理：

| 操作 | 命令 |
|------|------|
| 启用 | `-setsocksfirewallproxy <service> 127.0.0.1 7890` + `-setsocksfirewallproxystate on` |
| 禁用 | `-setsocksfirewallproxystate <service> off` |
| 查询 | `-getsocksfirewallproxy <service>` |

- 自动枚举所有活跃网络服务
- 内核意外崩溃时自动清理系统代理设置

## 崩溃恢复

```
进程终止 → terminationHandler
  ├─ 正常 stop() → isStoppingNormally = true → 跳过
  └─ 崩溃 → isStoppingNormally = false
       ├─ setSystemProxy(false)        自动清理代理
       └─ post(.mihomoCrashed)         通知 UI 弹窗
```

## 配置格式支持

| 格式 | 检测方式 | 处理 |
|------|----------|------|
| Base64 编码 | 尝试 Base64 解码 | 解码后重新识别 |
| URI 列表 | 所有非空行均为 `scheme://...` 格式 | 生成完整 YAML（含 DNS、代理组、规则） |
| YAML 配置 | 包含 `proxies:` 或 `rules:` | 直接使用 |

URI 到 YAML 的转换目前支持 `anytls` 和 `ss`/`shadowsocks` 协议。
