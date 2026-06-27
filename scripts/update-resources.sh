#!/bin/bash
# =============================================================================
# iClash 内置资源更新脚本
# 更新 iClashSource/Resources/ 下的 mihomo 内核和 Country.mmdb 数据库
# 用法: ./scripts/update-resources.sh [--only-mihomo|--only-mmdb]
# =============================================================================

set -euo pipefail

RESOURCES_DIR="iClashSource/Resources"
MIHOMO_PATH="$RESOURCES_DIR/mihomo"
MMDB_PATH="$RESOURCES_DIR/Country.mmdb"
MIHOMO_ARCH="arm64"

update_mmdb() {
    echo "=== 更新 Country.mmdb ==="
    local url="https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb"
    echo "下载: $url"
    curl -fLSo "$MMDB_PATH" "$url"
    echo "SHA256: $(shasum -a 256 "$MMDB_PATH" | cut -d' ' -f1)"
    echo "大小: $(ls -lh "$MMDB_PATH" | awk '{print $5}')"
    echo "✅ Country.mmdb 已更新"
}

update_mihomo() {
    echo "=== 更新 Mihomo 内核 ==="

    # 获取最新版本号
    local latest
    latest=$(gh release view --repo MetaCubeX/mihomo --json tagName -q .tagName 2>/dev/null)
    if [ -z "$latest" ]; then
        echo "❌ 无法获取最新版本号"
        exit 1
    fi
    echo "最新版本: $latest"

    # 检查是否已是最新
    if [ -f "$MIHOMO_PATH" ]; then
        local current
        current=$(strings "$MIHOMO_PATH" | grep -m1 "^v[0-9]\+\.[0-9]\+\.[0-9]\+" || echo "")
        if [ "$current" = "$latest" ]; then
            echo "✅ 当前版本 ($current) 已是最新，跳过"
            return 0
        fi
        echo "当前版本: $current → $latest"
    fi

    # 下载
    local filename="mihomo-darwin-${MIHOMO_ARCH}-${latest}.gz"
    echo "下载: $filename"
    gh release download "$latest" --repo MetaCubeX/mihomo -p "$filename" -O "/tmp/${filename}"

    # 解压替换
    gunzip -c "/tmp/${filename}" > "$MIHOMO_PATH"
    chmod +x "$MIHOMO_PATH"
    rm "/tmp/${filename}"

    # 验证
    local actual
    actual=$("$MIHOMO_PATH" version 2>/dev/null | grep -m1 "^v[0-9]" || strings "$MIHOMO_PATH" | grep -m1 "^v[0-9]\+\.[0-9]\+\.[0-9]\+")
    echo "验证版本: $actual"
    if [ "$actual" != "$latest" ]; then
        echo "⚠️  版本不匹配（预期 $latest，实际 $actual）"
    fi
    echo "✅ Mihomo 内核已更新 ($actual)"
}

# --- 主流程 ---

cd "$(dirname "$0")/.."

case "${1:-}" in
    --only-mihomo) update_mihomo ;;
    --only-mmdb)   update_mmdb ;;
    *)
        update_mmdb
        echo ""
        update_mihomo
        ;;
esac

echo ""
echo "=== 全部完成 ==="
