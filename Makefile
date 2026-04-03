# iClash Makefile
# 用于构建 macOS 应用程序
# 作者: David
# 版本: 2.0

.PHONY: debug push help _update_version

# =============================================================================
# 项目配置
# =============================================================================

PROJECT_NAME = iClash
SCHEME_NAME = iClash
BUILD_DIR = build
DERIVED_DATA_DIR = ~/Library/Developer/Xcode/DerivedData
INSTALL_DIR = /Applications
ARCHIVE_DIR = archive

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
	@echo "$(CYAN)iClash 构建系统$(NC) "
	@echo "$(CYAN)=================$(NC) "
	@echo ""
	@echo "$(GREEN)核心命令:$(NC)"
	@echo "  $(YELLOW)debug$(NC)       - 构建并运行 Debug 版本"
	@echo "  $(YELLOW)push$(NC)        - 构建、安装、更新版本并推送到Git (需要 MSG=\"提交信息\")"
	@echo ""
	@echo "$(GREEN)其他:$(NC)"
	@echo "  $(YELLOW)help$(NC)        - 显示此帮助信息"
	@echo ""
	@echo "$(GREEN)使用示例:$(NC)"
	@echo "  $(CYAN)make debug$(NC)                    - 开发调试"
	@echo "  $(CYAN)make push MSG=\"修复bug\"$(NC)       - 完整发布流程"

debug:
	@echo "$(BLUE)开始 Debug 构建和运行...$(NC)"
	@echo "$(YELLOW)1. 停止运行中的应用...$(NC)"
	@pkill -f "$(PROJECT_NAME)" 2>/dev/null || true
	@echo "$(YELLOW)2. 清理构建文件...$(NC)"
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DERIVED_DATA_DIR)/$(PROJECT_NAME)-*
	@rm -rf $(ARCHIVE_DIR)
	@echo "$(GREEN)✅ 清理完成$(NC)"
	@echo "$(YELLOW)3. 构建 Debug 版本...$(NC)"
	@xcodebuild \
		-project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME_NAME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		-destination 'platform=macOS' \
		build
	@echo "$(GREEN)✅ Debug 构建完成$(NC)"

	@echo "$(YELLOW)4. 启动 Debug 应用...$(NC)"
	@APP_PATH=$$(find $(BUILD_DIR) -name "$(PROJECT_NAME).app" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		open "$$APP_PATH"; \
		echo "$(GREEN)✅ 应用已启动$(NC)"; \
	else \
		echo "$(RED)❌ 找不到构建的应用程序$(NC)"; \
		exit 1; \
	fi

_update_version:
	@echo "$(YELLOW)更新版本信息...$(NC)"
	@INFO_PLIST="iClashSource/Supporting/Info.plist"; \
	PROJECT_FILE="$(PROJECT_NAME).xcodeproj/project.pbxproj"; \
	if [ -f "$$INFO_PLIST" ] && [ -f "$$PROJECT_FILE" ]; then \
		CURRENT_VERSION=$$(xcodebuild -project $(PROJECT_NAME).xcodeproj -showBuildSettings | grep "MARKETING_VERSION" | head -1 | awk '{print $$3}' || echo "1.0.0"); \
		echo "$(CYAN)当前版本: $$CURRENT_VERSION$(NC)"; \
		MAJOR=$$(echo $$CURRENT_VERSION | cut -d. -f1); \
		MINOR=$$(echo $$CURRENT_VERSION | cut -d. -f2); \
		PATCH=$$(echo $$CURRENT_VERSION | cut -d. -f3 2>/dev/null || echo "0"); \
		NEW_PATCH=$$((PATCH + 1)); \
		NEW_VERSION="$$MAJOR.$$MINOR.$$NEW_PATCH"; \
		BUILD_NUMBER=$$(date +%Y%m%d%H%M%S); \
		echo "$(CYAN)新版本: $$NEW_VERSION$(NC)"; \
		echo "$(CYAN)构建号: $$BUILD_NUMBER$(NC)"; \
		plutil -replace CFBundleShortVersionString -string "$$NEW_VERSION" "$$INFO_PLIST"; \
		plutil -replace CFBundleVersion -string "$$BUILD_NUMBER" "$$INFO_PLIST"; \
		sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $$NEW_VERSION/g" "$$PROJECT_FILE"; \
		sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $$BUILD_NUMBER/g" "$$PROJECT_FILE"; \
		if [ -f "README.md" ]; then \
			echo "$(CYAN)更新 README.md 版本徽章...$(NC)"; \
			sed -i '' "s/version-v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/version-v$$NEW_VERSION/g" "README.md"; \
			echo "$(GREEN)README.md 版本徽章已更新$(NC)"; \
		fi; \
		echo "$(GREEN)版本信息已更新$(NC)"; \
	else \
		echo "$(RED)错误: 找不到 Info.plist 或项目文件$(NC)"; \
		exit 1; \
	fi

push:
	@echo "$(BLUE)开始完整构建安装和推送流程...$(NC)"
	@if [ -z "$(MSG)" ]; then \
		echo "$(RED)错误: 请提供提交信息$(NC)"; \
		echo "$(YELLOW)使用方法: make push MSG=\"你的提交信息\"$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)1. 停止运行中的应用...$(NC)"
	@pkill -f "$(PROJECT_NAME)" 2>/dev/null || true
	@echo "$(YELLOW)2. 卸载旧版本...$(NC)" 
	@rm -rf "$(INSTALL_DIR)/$(PROJECT_NAME).app" 2>/dev/null || true
	@echo "$(GREEN)✅ 旧版本已卸载$(NC)"
	@echo "$(YELLOW)3. 清理构建文件...$(NC)"
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DERIVED_DATA_DIR)/$(PROJECT_NAME)-*
	@rm -rf $(ARCHIVE_DIR)
	@echo "$(GREEN)✅ 清理完成$(NC)"
	@echo "$(YELLOW)4. 更新版本信息...$(NC)"
	@$(MAKE) _update_version
	@echo "$(YELLOW)5. 构建 Release 版本...$(NC)"
	@xcodebuild \
		-project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME_NAME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		-destination 'platform=macOS' \
		build
	@echo "$(GREEN)✅ Release 构建完成$(NC)"

	@echo "$(YELLOW)6. 安装新版本...$(NC)"
	@APP_PATH=$$(find $(BUILD_DIR) -name "$(PROJECT_NAME).app" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		cp -R "$$APP_PATH" $(INSTALL_DIR)/; \
		echo "$(GREEN)✅ 安装完成: $(INSTALL_DIR)/$(PROJECT_NAME).app$(NC)"; \
	else \
		echo "$(RED)❌ 错误: 找不到构建的应用程序$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)7. 提交并推送到GitHub...$(NC)"
	@CURRENT_BRANCH=$$(git branch --show-current); \
	if [ -z "$$CURRENT_BRANCH" ]; then \
		echo "$(RED)错误: 无法获取当前分支$(NC)"; \
		exit 1; \
	fi; \
	echo "$(CYAN)当前分支: $$CURRENT_BRANCH$(NC)"; \
	git add .; \
	git commit -m "$(MSG)"; \
	git push origin "$$CURRENT_BRANCH"; \
	echo "$(GREEN)✅ 提交并推送完成: $(MSG)$(NC)"
