# Changelog

> iClash — 基于 Mihomo 内核的 macOS 菜单栏代理客户端。Swift 开发，支持多种代理协议和订阅格式。

## 1.6.8 — 2026-08-16

- **Fix**: Quit now disables the system proxy set by the app before stopping the kernel — no more dead-proxy disconnection after exit
- **Fix**: "Start Proxy" verifies the kernel is running first; auto-starts it if not, and rolls back (proxy stays off) if startup fails
- **Feature**: App icon regenerated with `chart.bar.fill` to match the menu bar icon; `scripts/gen_icon.swift` now renders at deterministic 1x pixel sizes
- **Tests**: Add 7 AppCoordinator tests (48 total, all passing)

## 1.6.7 — 2026-08-03

- **Feature**: Upgrade Mihomo kernel to v1.19.29
- **Feature**: Auto-sync Kernel/GeoIP from Bundle to config dir when Bundle resource is newer (mod-time comparison) — app updates propagate new kernel/GeoIP automatically
- **Update**: User-Agent Mihomo/1.18.1 → 1.19.27; Country.mmdb refreshed (Loyalsoldier/geoip 20260702)
- **Fix**: DaemonLogger `readAll()` now protected by serial queue — no half-read data under concurrency
- **Chore**: `update-resources.sh` — `chmod +w` before overwrite, kernel replaced with `555` permission

## 1.6.6 — 2026-06-28

- **Feature**: Settings window redesigned in iRelay style — title + Cancel/Save buttons + keyboard shortcuts + monospace font + 560px width for long subscription links

## 1.6.5 — 2026-06-28

- **Refactor**: Split `MihomoService` (527 lines) into three focused components: `MihomoService` (lifecycle), `MihomoAPIClient` (HTTP API), `NetworkServiceManager` (networksetup)
- **Fix**: YAML parser now supports block format (`- name: xxx\n    type: select`) in addition to inline format — fixes empty menu for standard-format subscriptions
- **Refactor**: `isStoppingNormally` flag replaced with `Process.TerminationReason` — eliminates race condition between crash and normal stop detection
- **Feature**: DaemonLogger now mirrors to OSLog (viewable in Console.app) and auto-rotates at 1 MB, keeping one archive
- **Feature**: Subscription download enforced with 5 MB cap — rejects oversized subscriptions before OOM risk
- **Feature**: `mihomo` and `Country.mmdb` bootstrapped from Bundle to `~/.config/iclash/` on init — always run from config dir, auto-repair if corrupted
- **Feature**: `ProxyManagerDelegate` callback on background refresh completion — menu auto-rebuilds when proxy list updates
- **Feature**: `resolveMihomoPath` now prefers user-installed kernel in config dir, bootstraps from Bundle if missing
- **Tests**: Add 16 new unit tests (19 total, all passing); fix 4 pre-existing broken tests

## 1.6.4 — 2026-06-28

- **Fix**: Kernel crash loop — terminationHandler from old process corrupts new process state, causing infinite crash-restart cycle
- **Robustness**: Add crash circuit breaker — 3+ crashes in 30s triggers fatal alert instead of infinite retry
- **Chore**: Read app version from Info.plist at startup instead of hardcoded string

## 1.6.3 — 2026-06-28

- **Log**: Add daemon.log at `~/.config/iclash/daemon.log`, log all key actions for troubleshooting
- **Optimize**: Skip kernel restart when subscription content hasn't changed
- **Stability**: Disable system proxy before subscription download to avoid interference
- **Robustness**: Use absolute path for providers.txt in generated config

## 1.6.2 — 2026-06-28

- **Proxy**: Switch from SOCKS-only to HTTP + HTTPS + SOCKS all three, all pointing to mixed-port 7890
- **Detection**: Check HTTP proxy state instead of SOCKS for menu display

## 1.6.1 — 2026-06-28

- **Simplify**: Replace URI parsing with Mihomo native proxy-providers, remove 400+ lines of parser code
- **Config**: Subscription URI list saved as `providers.txt`, kernel handles parsing natively
- **Proxy state**: App no longer manages proxy state — only reads on menu open, toggles on user click
- **Startup**: Skip re-download when config.yaml exists, start kernel directly (faster launch)
- **Cleanup**: Remove unused imports, dead code, redundant protocol conformance
- **Icon**: New app icon (bar chart style)

## 1.6.0 — 2026-06-27

- **Simplify**: Remove KernelUpdater, kernel auto-update, rely on app releases for resource updates
- **Crash detection**: Post user notification when mihomo kernel crashes unexpectedly, auto-clean system proxy
- **Menu sync**: Real-time proxy / kernel state check on each menu open; display errors at menu bottom, auto-clear on close
- **Subscription UI**: Minimal input field + save button, widened window 600px
- **Performance**: Fix double subscription download on startup
- **Resources**: Refresh Country.mmdb to Loyalsoldier/geoip `202606250051`
- **Scripts**: Add `scripts/update-resources.sh` for one-click mihomo + mmdb update
- **Docs**: Add ARCHITECTURE.md, overhaul README, update upgrade-resources.md
- Upgrade bundled Mihomo kernel to v1.19.27 (was v1.19.26) — 修复 quic sniffer / trojan / socks4 / vision TLS filter 等多个崩溃级 Bug；新增 anytls/trojan/vless 监听器 `allow-insecure` 配置
- Refresh Country.mmdb to Loyalsoldier/geoip `202606182327` (5.79 MB → 8.36 MB)，提升 GeoIP 匹配精度

## 0.4.0 — 2026-05-22
- Refactor: revert to UserDefaults for subscription URL
- Refactor: remove UserDefaults fallback, config file only
- Add config file at ~/.config/iclash/config.json to replace env var
- Update README and CLAUDE.md for UserDefaults storage

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

## 0.2.0 — 2026-04-09
- Fix kernel update failure: install to user config directory instead of read-only Bundle
- Migrate subscription settings to UserDefaults and unify user directory kernel path

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