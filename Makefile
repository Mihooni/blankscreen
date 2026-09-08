# blankscreen —— 关屏但不睡眠
# 用法:
#   make            构建 CLI + 菜单栏 App（universal binary）
#   make install    安装 CLI 到 Homebrew 前缀（arm64 用 /opt/homebrew/bin，Intel 用 /usr/local/bin），App 到 /Applications
#   make uninstall  卸载以上两者（含 launchd 登录项）
#   make dev-tools  编译开发调试小工具到 build/dev-tools/
#   make clean

CC      = swiftc
TARGETS = arm64-apple-macosx13.0 x86_64-apple-macosx13.0
# 安装前缀：Apple Silicon (arm64) 走 /opt/homebrew/bin，Intel 走 /usr/local/bin，
# 与 Homebrew 默认前缀一致，避免同一机器出现两份二进制导致 `which` 混淆。
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M), arm64)
BINDIR  := /opt/homebrew/bin
else
BINDIR  := /usr/local/bin
endif
APPSRC  = build/BlankScreenBar.app
DEST    = /Applications/BlankScreenBar.app

.PHONY: all cli app install install-cli uninstall dev-tools clean

all: cli app

# 通用规则：单文件 Swift 程序按架构分别编译后 lipo 合并
define compile-universal
	@mkdir -p build
	$(foreach t,$(TARGETS),$(CC) -O -target $(t) $(1) -o build/$(notdir $(basename $(1)))_$(t);)
	lipo -create $(foreach t,$(TARGETS),build/$(notdir $(basename $(1)))_$(t)) -output $(2)
endef

cli:
	$(call compile-universal,Sources/blankscreen.swift,build/blankscreen)

app: build/BlankScreenBar.app

build/BlankScreenBar.app: Sources/BlankScreenBar.swift Sources/Info.plist Sources/AppIcon.icns
	@mkdir -p build/BlankScreenBar.app/Contents/MacOS build/BlankScreenBar.app/Contents/Resources
	$(foreach t,$(TARGETS),$(CC) -O -target $(t) Sources/BlankScreenBar.swift -o build/bsb_$(t);)
	lipo -create $(foreach t,$(TARGETS),build/bsb_$(t)) -output build/BlankScreenBar.app/Contents/MacOS/BlankScreenBar
	cp Sources/Info.plist build/BlankScreenBar.app/Contents/Info.plist
	cp Sources/AppIcon.icns build/BlankScreenBar.app/Contents/Resources/AppIcon.icns
	-codesign --force --deep -s - build/BlankScreenBar.app 2>/dev/null
	@echo "==> 构建完成: build/BlankScreenBar.app"

install: cli app install-cli
	@# 先删后装：直接覆盖正在运行的可执行文件会因签名缓存失效被内核 kill（exit 137）
	-pkill -f "$(DEST)/Contents/MacOS/BlankScreenBar" 2>/dev/null || true
	@sleep 1
	-rm -rf "$(DEST)"
	cp -R "$(APPSRC)" "$(DEST)"
	-xattr -dr com.apple.quarantine "$(DEST)" 2>/dev/null || true
	@echo "==> 已安装: $(DEST) 和 $(BINDIR)/blankscreen"
	@echo "==> 启动:   open -a BlankScreenBar  （或在设置里勾选「登录时自动启动」）"

install-cli:
	@mkdir -p $(BINDIR)
	install -m 0755 build/blankscreen $(BINDIR)/blankscreen

uninstall:
	-launchctl bootout gui/$$(id -u)/com.blankscreen.bar 2>/dev/null || true
	-launchctl bootout gui/$$(id -u)/com.blankscreen.agent 2>/dev/null || true
	-rm -f ~/Library/LaunchAgents/com.blankscreen.bar.plist
	-rm -f ~/Library/LaunchAgents/com.blankscreen.agent.plist
	-pkill -f "$(DEST)/Contents/MacOS/BlankScreenBar" 2>/dev/null || true
	@sleep 1
	-rm -rf "$(DEST)"
	-rm -f $(BINDIR)/blankscreen
	@echo "==> 已卸载（配置与日志保留在 ~/Library/Application Support/blankscreen/，可手动删除）"

dev-tools:
	@mkdir -p build/dev-tools
	@for f in dev-tools/*.swift; do \
		$(CC) -O -target arm64-apple-macosx13.0 $$f -o build/dev-tools/$$(basename $${f%.swift}); \
	done
	@echo "==> 开发工具已编译到 build/dev-tools/"

clean:
	rm -rf build
