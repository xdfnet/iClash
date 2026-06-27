# 内置资源升级指南

iClash 在 `iClashSource/Resources/` 下内置了两个外部资源文件，随 app 版本一起发布。发版前需要确保它们是最新的。

## 资源清单

| 文件 | 路径 | 作用 |
|------|------|------|
| `mihomo` | `iClashSource/Resources/mihomo` | 代理内核二进制 |
| `Country.mmdb` | `iClashSource/Resources/Country.mmdb` | GeoIP 数据库（GEOIP 规则分流用） |

运行时会从 Bundle 直接读取（`mihomo` 从 Bundle 路径启动，`Country.mmdb` 通过符号链接触达），无需额外拷贝。

## 一键更新

```bash
./scripts/update-resources.sh
```

执行后会依次更新 Country.mmdb 和 Mihomo 内核到最新版本。支持子命令：

- `--only-mmdb`：只更新 Country.mmdb
- `--only-mihomo`：只更新 Mihomo 内核

## 手动更新（备选）

### Mihomo 内核

上游仓库：[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)

```bash
# 获取最新版本号
VERSION=$(curl -fsS https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    | grep -m1 '"tag_name"' | sed 's/.*"tag_name": "\(.*\)",/\1/')

# 下载并替换
gh release download "$VERSION" --repo MetaCubeX/mihomo \
    -p "mihomo-darwin-arm64-${VERSION}.gz" \
    -O /tmp/mihomo.gz
gunzip -c /tmp/mihomo.gz > iClashSource/Resources/mihomo
chmod +x iClashSource/Resources/mihomo

# 验证
./iClashSource/Resources/mihomo version
```

### Country.mmdb

上游仓库：[Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)

```bash
curl -Lo iClashSource/Resources/Country.mmdb \
  https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb
```

## 验证完整性

```bash
ls -lh iClashSource/Resources/
# 期望看到:
# - mihomo         (约 20-30 MB)
# - Country.mmdb   (约 8 MB)
# - Assets.xcassets/
```

## 发版流程

资源更新后用 `make push` 自动构建 Release 并发布：

```bash
make push MSG="upgrade: mihomo v1.19.28, refresh Country.mmdb"
```

在此之前确保：
- `iClashSource/Resources/mihomo` 已更新为新版本
- `iClashSource/Resources/Country.mmdb` 已刷新
- `CHANGELOG.md` 已记录变更
