UUID := cuotax@jpnurmi.github.com
GNOME_DIR := gnome
GNOME_EXTENSION_DIR := $(GNOME_DIR)/extension
GNOME_ARCHIVE := dist/gnome/$(UUID).shell-extension.zip
MACOS_DIR := macos
MACOS_BUILD_APP := dist/macos/CuotaX.app
WINDOWS_DIR := windows
SCREENSHOT_DIR ?= $(CURDIR)/dist/screenshots
ifeq ($(OS),Windows_NT)
SYSTEM := Windows_NT
else
SYSTEM := $(shell uname -s)
endif
MACOS_APP := $(HOME)/Applications/CuotaX.app
PLATFORM_FORMAT :=
PLATFORM_FORMAT_CHECK :=

ifeq ($(SYSTEM),Darwin)
PLATFORM_FORMAT := swift format --in-place --recursive $(MACOS_DIR)/Sources $(MACOS_DIR)/Tests $(MACOS_DIR)/Package.swift
PLATFORM_FORMAT_CHECK := swift format lint --recursive $(MACOS_DIR)/Sources $(MACOS_DIR)/Tests $(MACOS_DIR)/Package.swift
else ifeq ($(SYSTEM),Windows_NT)
PLATFORM_FORMAT := powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(WINDOWS_DIR)/scripts/format.ps1
PLATFORM_FORMAT_CHECK := powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(WINDOWS_DIR)/scripts/format.ps1 -Check
endif

.PHONY: build disable enable format format-check install lint screenshot test uninstall verify

lint:
	npm --prefix $(GNOME_DIR) run lint

format:
	npm --prefix $(GNOME_DIR) run format
	$(PLATFORM_FORMAT)

format-check:
	npm --prefix $(GNOME_DIR) run format:check
	$(PLATFORM_FORMAT_CHECK)

ifeq ($(SYSTEM),Darwin)

build:
	$(MACOS_DIR)/scripts/build-app.sh

test:
	swift test --package-path $(MACOS_DIR)

screenshot:
	swift run --package-path $(MACOS_DIR) -c release CuotaX --screenshot "$(SCREENSHOT_DIR)/macos.png"

verify: build
	codesign --verify --deep --strict --verbose=2 $(MACOS_BUILD_APP)
	plutil -lint $(MACOS_BUILD_APP)/Contents/Info.plist

install: build
	@pkill -x CuotaX >/dev/null 2>&1 || true
	@case "$(MACOS_APP)" in */Applications/CuotaX.app) ;; *) echo "Refusing to remove unexpected path: $(MACOS_APP)" >&2; exit 1;; esac
	rm -rf "$(MACOS_APP)"
	mkdir -p "$(dir $(MACOS_APP))"
	ditto "$(MACOS_BUILD_APP)" "$(MACOS_APP)"
	open "$(MACOS_APP)"

uninstall:
	@if [ -x "$(MACOS_APP)/Contents/MacOS/CuotaX" ]; then \
		"$(MACOS_APP)/Contents/MacOS/CuotaX" --unregister; \
	fi
	@pkill -x CuotaX >/dev/null 2>&1 || true
	@case "$(MACOS_APP)" in */Applications/CuotaX.app) ;; *) echo "Refusing to remove unexpected path: $(MACOS_APP)" >&2; exit 1;; esac
	rm -rf "$(MACOS_APP)"

enable disable:
	@echo "$@ is only available for the GNOME Shell extension" >&2
	@exit 1

else ifeq ($(SYSTEM),Linux)

build:
	$(GNOME_DIR)/scripts/package.sh

test:
	node --check $(GNOME_EXTENSION_DIR)/backend.js
	node --check $(GNOME_EXTENSION_DIR)/extension.js
	node --check $(GNOME_EXTENSION_DIR)/quota.js
	node --check $(GNOME_EXTENSION_DIR)/update.js
	gjs -m $(GNOME_DIR)/tests/test_quota.js
	gjs -m $(GNOME_DIR)/tests/test_update.js
	CODEX_TEST_COMMAND="$(CURDIR)/$(GNOME_DIR)/tests/fixtures/codex" gjs -m $(GNOME_DIR)/tests/test_backend.js

screenshot:
	mkdir -p "$(SCREENSHOT_DIR)"
	TZ=UTC gjs -m $(GNOME_DIR)/scripts/screenshot.js "$(SCREENSHOT_DIR)/gnome.png"

verify: build
	unzip -t "$(GNOME_ARCHIVE)"

install: build
	gnome-extensions install --force "$(GNOME_ARCHIVE)"
	@if gnome-extensions info "$(UUID)" >/dev/null 2>&1; then \
		gnome-extensions enable "$(UUID)"; \
	else \
		echo "Installed $(UUID). Log out and back in, then run: make enable"; \
	fi

enable:
	gnome-extensions enable "$(UUID)"

disable:
	gnome-extensions disable "$(UUID)"

uninstall:
	gnome-extensions uninstall "$(UUID)"

else ifeq ($(SYSTEM),Windows_NT)

build:
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(WINDOWS_DIR)/scripts/build.ps1

test:
	dotnet run --project $(WINDOWS_DIR)/CuotaX.Tests/CuotaX.Tests.csproj --configuration Release

screenshot:
	dotnet run --project $(WINDOWS_DIR)/CuotaX/CuotaX.csproj --configuration Release -- --screenshot "$(SCREENSHOT_DIR)/windows.png"

verify: build
	powershell.exe -NoProfile -Command "if (-not (Test-Path -LiteralPath 'dist/windows/CuotaX.exe')) { exit 1 }"

install:
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(WINDOWS_DIR)/scripts/install.ps1

uninstall:
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(WINDOWS_DIR)/scripts/uninstall.ps1

enable disable:
	@echo "$@ is only available for the GNOME Shell extension" >&2
	@exit 1

else

build install test uninstall enable disable screenshot verify:
	@echo "Unsupported platform: $(SYSTEM)" >&2
	@exit 1

endif
