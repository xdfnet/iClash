# iClash

> 基于 Mihomo 内核的 macOS 菜单栏代理客户端

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## 特性

- **纯菜单栏应用** — 不占用 Dock 图标，轻量简洁
- **启动即连接** — 应用启动后自动连接代理
- **订阅支持** — 支持自定义订阅地址，自动拉取节点配置
- **系统代理** — 自动设置 SOCKS 系统代理
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

1. 运行应用，菜单栏会出现 iClash 图标（圆点表示运行状态）
2. 点击图标查看代理节点列表
3. 选择节点切换代理
4. 点击"设置订阅"修改订阅地址
5. 点击"内核版本"检查内核更新

### 3. 配置订阅

订阅地址保存在应用配置中（UserDefaults）：

1. 点击菜单栏图标
2. 点击"设置订阅"
3. 输入订阅地址并保存
4. 应用自动重新加载配置

## 菜单说明

| 选项 | 说明 |
|------|------|
| 切换节点 | 查看和切换代理节点 |
| 设置订阅 | 修改订阅地址 |
| 版本更新 | 查看当前/最新内核版本，可一键更新 |
| 退出 | 关闭代理并退出应用 |

## 内核版本

### 稳定版更新

应用内置一键更新稳定版内核功能：

1. 点击菜单栏"内核版本"
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
    ├── AppSettings.swift       # 应用设置（订阅地址）
    ├── MihomoService.swift     # 内核管理 + API
    ├── ConfigManager.swift     # 配置管理 + YAML解析
    ├── ProxyManager.swift       # 代理列表缓存管理
    ├── StatusBarController.swift # 状态栏控制
    ├── MenuController.swift    # 菜单构建和交互
    ├── SettingsWindowController.swift # 设置窗口
    ├── KernelUpdater.swift      # 内核更新逻辑
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
