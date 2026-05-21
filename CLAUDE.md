# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

iClash 是一个基于 Mihomo 内核的 macOS 菜单栏代理客户端，支持节点订阅、代理切换和系统代理控制。

## 构建与运行

```bash
cd /Users/admin/iCode/iClash

# 调试构建
make debug

# 发布构建
make push MSG="提交信息"
```

## 项目配置

| 配置项 | 值 |
|--------|-----|
| 最低 macOS | 15.0 |
| Swift 版本 | 6.2 |
| Xcode 版本 | 16.0 |
| Bundle ID | David.iClash |
| 开发团队 | K9UF7A2D7Y |

## 架构

### 核心组件

| 组件 | 职责 |
|------|------|
| `iClashApp.swift` | SwiftUI App 入口 + AppDelegate |
| `MihomoService.swift` | 内核生命周期与系统代理控制 |
| `ConfigManager.swift` | 订阅下载、配置解析与运行时配置生成 |
| `ProxyManager.swift` | 代理列表缓存与节点切换 |
| `KernelUpdater.swift` | 内核版本检查与更新 |
| `MenuController.swift` | 菜单构建与交互 |

### 代理协议支持

- AnyTLS
- Shadowsocks (SS)
- VMess
- VLESS
- Trojan
- Hysteria
- TUIC
- WireGuard

### 内置资源

- Mihomo 内核二进制
- GeoIP 数据库（Country.mmdb）

## 配置

订阅地址通过菜单栏 `iClash → 订阅设置` 输入，保存在系统原生 `UserDefaults` 中。

无需环境变量或手动编辑配置文件。

支持以下订阅格式：
- Base64 编码
- URI 列表（AnyTLS / SS / VMess / VLESS / Trojan / Hysteria / TUIC / WireGuard）
- YAML 配置

## 数据存储

```
~/.config/iclash/
├── config.yaml       # 运行时生成的 mihomo 配置
├── run               # 内核运行时文件
└── Country.mmdb      # GeoIP 数据库
```

```
~/Library/Preferences/David.iClash.plist   # UserDefaults（订阅地址）
```

## 技术特点

- 纯菜单栏应用（`LSUIElement = true`），不占 Dock 图标
- 内置 Mihomo 二进制，无需额外安装
- 内核运行状态与系统代理开关解耦
- 订阅内容自动识别格式，URI 列表自动生成运行时 YAML
- 自动生成代理组和规则配置
