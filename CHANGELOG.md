# Changelog

> iClash — 基于 Mihomo 内核的 macOS 菜单栏代理客户端。Swift 开发，支持多种代理协议和订阅格式。

## 0.1.0 — 2026-04-03
- Initialize project with basic structure
- Add subscription management and proxy switching
- Integrate Mihomo kernel startup logic
- Set up system proxy control
- Show alert when subscription is missing
- Add MIT license and license notes
- Add Mihomo kernel source to README
- Update README and Makefile for iClash
- Reorder README sections

## 0.2.0 — 2026-04-09
- Fix kernel update failure: install to user config directory instead of read-only Bundle
- Migrate subscription settings to UserDefaults and unify user directory kernel path

## 0.3.0 — 2026-04-26
- Upgrade kernel to v1.19.24, parse HTML to get latest version
- Fix subscription settings save and close window behavior
- Fix version number: Info.plist uses MARKETING_VERSION variable, fix Makefile sed command
- Add make push to auto-update README version number
- Unify project configuration: macOS 26.0, Swift 6.2, Xcode 16.0, Bundle ID, development team
- Integrate GitHub Release creation
- Support zip upload to Release
- Unify README badge format
- Fix CLAUDE.md: macOS version from 26.0 to 15.0

## 0.4.0 — 2026-05-22
- Refactor: revert to UserDefaults for subscription URL
- Refactor: remove UserDefaults fallback, config file only
- Add config file at ~/.config/iclash/config.json to replace env var
- Update README and CLAUDE.md for UserDefaults storage
