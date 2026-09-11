# lidkeep —— 关屏但不睡眠
# 用法:
#   make            构建 CLI + 菜单栏 App（universal binary）
#   make pkg        产出可分发的 .pkg 安装器（App + CLI，带许可协议）
#   make install    安装 CLI 到 Homebrew 前缀（arm64 用 /opt/homebrew/bin，Intel 用 /usr/local/bin），App 到 /Applications
#   make uninstall  卸载以上两者（含 launchd 登录项）
#   make dev-tools  编译开发调试小工具到 build/dev-tools/
#   make clean

CC      = swiftc
TARGETS = arm64-apple-macosx13.0 x86_64-apple-macosx13.0

# 版本号：CI 传 VERSION=v1.3.2；本地默认取最近的 git tag，便于开发时辨认构建来源
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

# 禁止 cp 生成 ._xxx AppleDouble 元数据文件：否则打安装包时会把垃圾文件
# 一起塞进 payload（COPYFILE_DISABLE 对所有配方生效）
export COPYFILE_DISABLE := 1
# 安装前缀：Apple Silicon (arm64) 走 /opt/homebrew/bin，Intel 走 /usr/local/bin，
# 与 Homebrew 默认前缀一致，避免同一机器出现两份二进制导致 `which` 混淆。
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M), arm64)
BINDIR  := /opt/homebrew/bin
else
BINDIR  := /usr/local/bin
endif
APPSRC  = build/LidKeep.app
DEST    = /Applications/LidKeep.app

.PHONY: all cli app pkg dmg install install-cli uninstall dev-tools test clean icon

all: cli app

# 把版本写进二进制与 App 的 Info.plist（`lidkeep version` / 关于面板会显示）
.PHONY: version-file
version-file:
	@# Version.swift 是构建产物（已 gitignore），目录可能不存在于干净的 checkout 中
	@mkdir -p Sources/Shared
	@printf '// 由 Makefile 生成，请勿手改\nlet LK_VERSION = "%s"\nlet LK_COMMIT = "%s"\n' \
		"$(VERSION)" "$(COMMIT)" > Sources/Shared/Version.swift
	@# 注意：不要写 `sed -i ''`——部分环境下空后缀参数会被误解析，导致替换静默失败
	@# （错误被 2>/dev/null 吞掉，App 版本号会一直停在旧值）。-i.bak 单参数写法跨环境稳定。
	@sed -i.bak 's|<string>[0-9.]*</string><!--VERSION-->|<string>$(VERSION)</string><!--VERSION-->|' Sources/Info.plist && rm -f Sources/Info.plist.bak
	@echo "==> 版本: $(VERSION) ($(COMMIT))"

# 产出可直接分发的 .pkg 安装器（内含 App + CLI，带许可协议）
# 可指定版本: make pkg VERSION=v1.1.1
pkg: all
	@./packaging/make_pkg.sh $(VERSION)

# 产出拖拽安装镜像 .dmg（App + Applications 快捷方式 + CLI 一键安装脚本）
dmg: all
	@./packaging/make_dmg.sh $(VERSION)

# 重新生成应用图标（改完 Sources/mkicon.swift 后执行；之后需 make app 才会打进 App）
icon:
	@# 输出目录必须以 .iconset 结尾：iconutil 对裸目录名直接报 Invalid Iconset
	@rm -rf build/AppIcon.iconset
	@swift Sources/mkicon.swift build/AppIcon.iconset
	@iconutil -c icns build/AppIcon.iconset -o Sources/AppIcon.icns
	@echo "==> 图标已更新: Sources/AppIcon.icns（执行 make app 后生效）"

# 端到端冒烟测试：构建后跑真实关屏/恢复/防睡眠路径（会短暂黑屏约 4 秒）
test: cli
	@./dev-tools/smoke.sh

# 通用规则：单文件 Swift 程序按架构分别编译后 lipo 合并
# $(1)=源文件 $(2)=中间产物名 $(3)=输出路径
define compile-universal
	@mkdir -p build
	$(foreach t,$(TARGETS),$(CC) -O -target $(t) $(1) -o build/$(2)_$(t);)
	lipo -create $(foreach t,$(TARGETS),build/$(2)_$(t)) -output $(3)
endef

# 源码按 target 分目录：Swift 只有名为 main.swift 的文件允许顶层代码，
# 因此 CLI 与菜单栏 App 各有自己的 main.swift，共享代码放 Sources/Shared/。
cli: version-file
	$(call compile-universal,Sources/CLI/main.swift Sources/Shared/Version.swift Sources/Shared/L10n.swift,lidkeep,build/lidkeep)

app: build/LidKeep.app

build/LidKeep.app: Sources/Bar/main.swift Sources/Info.plist Sources/AppIcon.icns version-file
	@mkdir -p build/LidKeep.app/Contents/MacOS build/LidKeep.app/Contents/Resources
	$(foreach t,$(TARGETS),$(CC) -O -target $(t) Sources/Bar/main.swift Sources/Shared/Version.swift Sources/Shared/L10n.swift -o build/lk_$(t);)
	lipo -create $(foreach t,$(TARGETS),build/lk_$(t)) -output build/LidKeep.app/Contents/MacOS/LidKeep
	cp Sources/Info.plist build/LidKeep.app/Contents/Info.plist
	cp Sources/AppIcon.icns build/LidKeep.app/Contents/Resources/AppIcon.icns
	-codesign --force --deep -s - build/LidKeep.app 2>/dev/null
	@echo "==> 构建完成: build/LidKeep.app"

install: cli app install-cli
	@# 先删后装：直接覆盖正在运行的可执行文件会因签名缓存失效被内核 kill（exit 137）
	-pkill -f "$(DEST)/Contents/MacOS/LidKeep" 2>/dev/null || true
	@sleep 1
	-rm -rf "$(DEST)"
	cp -R "$(APPSRC)" "$(DEST)"
	-xattr -dr com.apple.quarantine "$(DEST)" 2>/dev/null || true
	@echo "==> 已安装: $(DEST) 和 $(BINDIR)/lidkeep"
	@echo "==> 启动:   open -a LidKeep  （或在设置里勾选「登录时自动启动」）"

install-cli:
	@mkdir -p $(BINDIR)
	install -m 0755 build/lidkeep $(BINDIR)/lidkeep

uninstall:
	-launchctl bootout gui/$$(id -u)/com.lidkeep.bar 2>/dev/null || true
	-launchctl bootout gui/$$(id -u)/com.lidkeep.agent 2>/dev/null || true
	-rm -f ~/Library/LaunchAgents/com.lidkeep.bar.plist
	-rm -f ~/Library/LaunchAgents/com.lidkeep.agent.plist
	-pkill -f "$(DEST)/Contents/MacOS/LidKeep" 2>/dev/null || true
	@sleep 1
	-rm -rf "$(DEST)"
	-rm -f $(BINDIR)/lidkeep
	@echo "==> 已卸载（配置与日志保留在 ~/Library/Application Support/LidKeep/，可手动删除）"

dev-tools:
	@mkdir -p build/dev-tools
	@for f in dev-tools/*.swift; do \
		$(CC) -O -target arm64-apple-macosx13.0 $$f -o build/dev-tools/$$(basename $${f%.swift}); \
	done
	@echo "==> 开发工具已编译到 build/dev-tools/"

clean:
	rm -rf build
