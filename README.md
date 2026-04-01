# iClash

> 基于 Mihomo 内核的 macOS 菜单栏代理客户端

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## 特性

- **纯菜单栏应用** — 不占用 Dock 图标，轻量简洁
- **启动即内核** — 应用启动后自动启动 Mihomo 内核，不自动设置系统代理
- **代理控制分离** — 内核启动/停止与系统代理设置相互独立
- **订阅支持** — 支持自定义订阅地址，自动拉取节点配置
- **AnyTLS 支持** — 支持 AnyTLS 协议订阅自动转换为完整配置
- **系统代理** — 点击"启动代理"后自动设置 SOCKS 系统代理
- **内置内核** — Mihomo 内核随应用打包，无需手动安装
- **内核更新** — 支持一键检查和更新稳定版内核

## 快速开始

### 1. 安装

```bash
# 克隆项目
git clone https://github.com/your-repo/iClash.git
cd iClash

# 安装 XcodeGen (如未安装)
brew install xcodegen

# 生成 Xcode 项目
xcodegen generate

# 编译
xcodebuild -project iClash.xcodeproj -scheme iClash -configuration Debug build
```

### 2. 使用

1. 运行应用，菜单栏会出现 iClash 图标
2. 内核自动启动（不自动设置系统代理）
3. 点击"启动代理"启用系统代理
4. 点击"切换节点"子菜单选择代理节点
5. 点击"版本更新"检查内核更新
6. 点击"退出"关闭内核并退出应用

## 菜单说明

| 选项 | 说明 |
|------|------|
| 启动代理 | 设置系统 SOCKS 代理指向 127.0.0.1:7890 |
| 停止代理 | 清除系统代理设置 |
| 切换节点 | 子菜单显示代理组和节点，可切换节点 |
| 版本更新 | 查看当前/最新内核版本，可一键更新 |
| 退出 | 停止内核并退出应用 |

## 工作原理

### 启动流程

```
应用启动 → 检查配置是否存在 → 不存在则下载订阅 → 启动内核 → 加载代理列表
```

### 内核与代理控制

- **内核**：负责代理协议的连接管理
- **系统代理**：将系统流量转发到内核的 SOCKS 端口（7890）

两者相互独立：
- 停止代理只清除系统代理设置，内核继续运行
- 退出应用会停止内核并清除系统代理

### 订阅配置

订阅地址保存在应用配置中（UserDefaults），默认订阅地址在首次启动时自动使用。

订阅返回的内容会被自动处理：
- **Base64 编码** → 自动解码
- **AnyTLS URI 列表** → 自动转换为完整的 Clash YAML 配置
- **完整配置** → 直接使用

## 内核版本

### 稳定版更新

应用内置一键更新稳定版内核功能：

1. 点击菜单栏"版本更新"
2. 查看当前内核版本和最新稳定版
3. 版本不同时点击"更新"即可

### 手动更新内核

如需手动更新，访问 [MetaCubeX/mihomo Releases](https://github.com/MetaCubeX/mihomo/releases/latest) 下载：

- **Apple Silicon (M1/M2/M3)** — 下载 `mihomo-darwin-arm64-v{version}.gz`
- **Intel Mac** — 下载 `mihomo-darwin-amd64-v{version}.gz`

```bash
# 解压
gunzip -c mihomo-darwin-arm64-v{version}.gz > iClashSource/Resources/mihomo

# 替换并编译
chmod +x iClashSource/Resources/mihomo
xcodegen generate
xcodebuild -project iClash.xcodeproj -scheme iClash -configuration Debug build
```

## 项目结构

```
iClash/
├── project.yml                 # XcodeGen 配置
├── iClash.entitlements        # 沙盒权限
├── iClash.xcodeproj/          # Xcode 项目
└── iClashSource/
    ├── iClashApp.swift        # 应用入口 + AppDelegate
    ├── AppSettings.swift       # 应用设置（订阅地址、UserDefaults）
    ├── DefaultRules.swift      # 默认规则配置（DNS、分流规则）
    ├── MihomoService.swift     # 内核管理 + API + 系统代理设置
    ├── ConfigManager.swift     # 配置管理 + 订阅下载 + YAML解析
    ├── ProxyManager.swift      # 代理列表缓存管理
    ├── StatusBarController.swift # 状态栏图标控制
    ├── MenuController.swift    # 菜单构建和交互
    ├── KernelUpdater.swift     # 内核更新逻辑
    ├── Resources/
    │   ├── Assets.xcassets/   # 图标资源
    │   ├── Country.mmdb      # GeoIP 数据库
    │   └── mihomo            # Mihomo 内核
    └── Supporting/
        └── Info.plist
```

## 系统要求

- macOS 14.0 (Sonoma) 或更高
- Apple Silicon 或 Intel Mac

## 免责声明

本应用仅供学习交流使用，请遵守当地法律法规。
