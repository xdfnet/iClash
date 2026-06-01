# iClash Makefile
# 用于构建 macOS 应用程序

.PHONY: help debug install uninstall push package _update_version _require_msg

# =============================================================================
# 项目配置
# =============================================================================

PROJECT_NAME = iClash
SCHEME_NAME = iClash
XCODEPROJ = $(PROJECT_NAME).xcodeproj
BUILD_DIR = build
DERIVED_DATA_DIR = ~/Library/Developer/Xcode/DerivedData
INSTALL_DIR = /Applications
PACKAGE_DIR = build/packages

# 颜色定义
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[0;33m
BLUE = \033[0;34m
CYAN = \033[0;36m
NC = \033[0m # No Color

# =============================================================================
# 默认目标
# =============================================================================

.DEFAULT_GOAL := help

# =============================================================================
# 帮助信息
# =============================================================================

help:
	@echo "$(CYAN)iClash 构建系统$(NC)"
	@echo "$(CYAN)=================$(NC)"
	@echo ""
	@echo "$(GREEN)核心命令:$(NC)"
	@echo "  $(YELLOW)debug$(NC)       - 构建并运行 Debug 版本"
	@echo "  $(YELLOW)install$(NC)      - 构建并安装 Release 版本 (不提交)"
	@echo "  $(YELLOW)uninstall$(NC)    - 卸载应用及运行时数据"
	@echo "  $(YELLOW)package$(NC)      - 打包 Release 为 zip (依赖 install)"
	@echo "  $(YELLOW)push$(NC)        - 构建、安装、打包、更新版本并推送 (需要 MSG=\"提交信息\")"
	@echo ""
	@echo "$(GREEN)使用示例:$(NC)"
	@echo "  $(CYAN)make debug$(NC)                    - 开发调试"
	@echo "  $(CYAN)make install$(NC)                  - Release 构建并安装"
	@echo "  $(CYAN)make package$(NC)                  - 打包 zip"
	@echo "  $(CYAN)make push MSG=\"修复bug\"$(NC)       - 完整发布流程"

debug:
	@echo "$(BLUE)开始 Debug 构建和运行...$(NC)"
	@echo "$(YELLOW)1. 停止运行中的应用...$(NC)"
	@pkill -f "$(PROJECT_NAME)" 2>/dev/null || true
	@echo "$(YELLOW)2. 清理构建文件...$(NC)"
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DERIVED_DATA_DIR)/$(PROJECT_NAME)-*
	@echo "$(GREEN)清理完成$(NC)"
	@echo "$(YELLOW)3. 构建 Debug 版本...$(NC)"
	@BUILD_NUMBER=$$(date +%Y%m%d%H%M%S); \
	xcodebuild \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME_NAME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		-destination 'platform=macOS' \
		CURRENT_PROJECT_VERSION=$$BUILD_NUMBER \
		build
	@echo "$(GREEN)Debug 构建完成$(NC)"

	@echo "$(YELLOW)4. 启动 Debug 应用...$(NC)"
	@APP_PATH=$$(find $(BUILD_DIR) -name "$(PROJECT_NAME).app" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		open "$$APP_PATH"; \
		echo "$(GREEN)应用已启动$(NC)"; \
	else \
		echo "$(RED)找不到构建的应用程序$(NC)"; \
		exit 1; \
	fi

install:
	@echo "$(BLUE)开始 Release 构建安装...$(NC)"
	@echo "$(YELLOW)1. 停止运行中的应用...$(NC)"
	@pkill -f "$(PROJECT_NAME)" 2>/dev/null || true
	@echo "$(YELLOW)2. 卸载旧版本...$(NC)"
	@rm -rf "$(INSTALL_DIR)/$(PROJECT_NAME).app" 2>/dev/null || true
	@echo "$(GREEN)旧版本已卸载$(NC)"
	@echo "$(YELLOW)3. 清理构建文件...$(NC)"
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DERIVED_DATA_DIR)/$(PROJECT_NAME)-*
	@echo "$(GREEN)清理完成$(NC)"
	@echo "$(YELLOW)4. 构建 Release 版本...$(NC)"
	@BUILD_NUMBER=$$(date +%Y%m%d%H%M%S); \
	xcodebuild \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME_NAME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		-destination 'platform=macOS' \
		CURRENT_PROJECT_VERSION=$$BUILD_NUMBER \
		build
	@echo "$(GREEN)Release 构建完成$(NC)"

	@echo "$(YELLOW)5. 安装到 Applications...$(NC)"
	@APP_PATH=$$(find $(BUILD_DIR) -name "$(PROJECT_NAME).app" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		cp -R "$$APP_PATH" $(INSTALL_DIR)/; \
		echo "$(GREEN)安装完成: $(INSTALL_DIR)/$(PROJECT_NAME).app$(NC)"; \
	else \
		echo "$(RED)错误: 找不到构建的应用程序$(NC)"; \
		exit 1; \
	fi

uninstall:
	@echo "$(BLUE)卸载 iClash...$(NC)"
	@echo "$(YELLOW)1. 停止运行中的应用...$(NC)"
	@pkill -f "$(PROJECT_NAME)" 2>/dev/null || true
	@echo "$(YELLOW)2. 移除应用...$(NC)"
	@rm -rf "$(INSTALL_DIR)/$(PROJECT_NAME).app" 2>/dev/null || true
	@echo "$(GREEN)应用已移除$(NC)"
	@echo "$(YELLOW)3. 移除运行时配置...$(NC)"
	@CONFIG_DIR="$$HOME/.config/iclash"; \
	if [ -d "$$CONFIG_DIR" ]; then \
		rm -rf "$$CONFIG_DIR"; \
		echo "$(GREEN)已删除: $$CONFIG_DIR$(NC)"; \
	fi
	@echo "$(YELLOW)4. 移除偏好设置...$(NC)"
	@defaults delete David.iClash 2>/dev/null || true
	@echo "$(GREEN)偏好设置已清除$(NC)"
	@echo "$(YELLOW)5. 清理构建文件...$(NC)"
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DERIVED_DATA_DIR)/$(PROJECT_NAME)-*
	@echo "$(GREEN)构建文件已清理$(NC)"
	@echo ""
	@echo "$(GREEN)✅ iClash 已完全卸载$(NC)"

_require_msg:
	@if [ -z "$(MSG)" ]; then \
		echo "$(RED)错误: 请提供提交信息$(NC)"; \
		echo "$(YELLOW)使用方法: make push MSG=\"提交信息\"$(NC)"; \
		exit 1; \
	fi

_update_version:
	@echo "$(YELLOW)递增版本号...$(NC)"
	@PBXPROJ="iClash.xcodeproj/project.pbxproj"; \
	CURRENT_VERSION=$$(grep -A1 'MARKETING_VERSION' "$$PBXPROJ" | grep '<string>' | head -1 | sed 's/.*<string>\([0-9.]*\)<\/string>.*/\1/'); \
	if [ -z "$$CURRENT_VERSION" ]; then \
		echo "$(RED)错误: 无法从 project.pbxproj 获取当前版本$(NC)"; \
		exit 1; \
	fi; \
	echo "$(CYAN)当前版本: $$CURRENT_VERSION$(NC)"; \
	MAJOR=$$(echo $$CURRENT_VERSION | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT_VERSION | cut -d. -f2); \
	PATCH=$$(echo $$CURRENT_VERSION | cut -d. -f3 2>/dev/null || echo "0"); \
	NEW_PATCH=$$((PATCH + 1)); \
	NEW_VERSION="$$MAJOR.$$MINOR.$$NEW_PATCH"; \
	echo "$(CYAN)新版本: $$NEW_VERSION$(NC)"; \
	sed -i '' "s|<string>$$CURRENT_VERSION<\/string>|<string>$$NEW_VERSION<\/string>|g" "$$PBXPROJ"; \
	sed -i '' "s|<string>1<\/string>|<string>1<\/string>|g" "$$PBXPROJ"; \
	echo "$(GREEN)project.pbxproj 版本已更新: $$CURRENT_VERSION → $$NEW_VERSION$(NC)"; \
	if grep -q "github.com/xdfnet/iClash/releases" README.md 2>/dev/null; then \
		echo "$(YELLOW)更新 README.md release URL...$(NC)"; \
		sed -i "" "s|github.com/xdfnet/iClash/releases/tag/[^)]*|github.com/xdfnet/iClash/releases/tag/v$$NEW_VERSION|g" README.md; \
		echo "$(GREEN)README.md 已更新$(NC)"; \
	fi

push: _require_msg _update_version install package
	@echo "$(YELLOW)提交并推送...$(NC)"
	@if git diff --quiet && git diff --cached --quiet; then \
		echo "$(CYAN)没有变更需要提交$(NC)"; \
	else \
		git add .; \
		git commit -m "$(MSG)"; \
		echo "$(GREEN)提交完成: $(MSG)$(NC)"; \
		git push; \
		echo "$(GREEN)推送完成$(NC)"; \
	fi
	@echo "$(YELLOW)创建 GitHub Release...$(NC)"
	@VERSION=$$(grep -A1 'MARKETING_VERSION' iClash.xcodeproj/project.pbxproj | grep '<string>' | head -1 | sed 's/.*<string>\([0-9.]*\)<\/string>.*/\1/'); \
	ZIP_PATH=$$(find $(PACKAGE_DIR) -name "$(PROJECT_NAME)-$$VERSION-*.zip" -type f | head -1); \
	gh release create "v$$VERSION" --title "iClash v$$VERSION" --notes "$(MSG)"; \
	if [ -n "$$ZIP_PATH" ]; then \
		gh release upload "v$$VERSION" "$$ZIP_PATH"; \
		echo "$(GREEN)已上传: $$ZIP_PATH$(NC)"; \
	fi; \
	echo "$(GREEN)Release 创建完成: https://github.com/xdfnet/iClash/releases/tag/v$$VERSION$(NC)"

package:
	@echo "$(BLUE)打包 Release 为 zip...$(NC)"
	@mkdir -p "$(PACKAGE_DIR)"
	@APP_PATH=$$(find $(BUILD_DIR) -name "$(PROJECT_NAME).app" -type d | head -1); \
	if [ -z "$$APP_PATH" ]; then \
		echo "$(RED)错误: 找不到构建的应用程序$(NC)"; \
		exit 1; \
	fi; \
	version=$$(grep -A1 'MARKETING_VERSION' iClash.xcodeproj/project.pbxproj | grep '<string>' | head -1 | sed 's/.*<string>\([0-9.]*\)<\/string>.*/\1/'); \
	build=$$(plutil -extract CFBundleVersion raw "$$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0"); \
	zip_path="$(PACKAGE_DIR)/$(PROJECT_NAME)-$$version-$$build.zip"; \
	rm -f "$$zip_path"; \
	ditto -c -k --keepParent "$$APP_PATH" "$$zip_path"; \
	echo "$(GREEN)已创建: $$zip_path$(NC)"
