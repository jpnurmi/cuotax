UUID := cuotax@jpnurmi.github.com
EXTENSION_DIR := src
ARCHIVE := dist/$(UUID).shell-extension.zip
ifeq ($(OS),Windows_NT)
SYSTEM := Windows_NT
else
SYSTEM := $(shell uname -s)
endif
MACOS_APP := $(HOME)/Applications/CuotaX.app
PLATFORM_FORMAT :=
PLATFORM_FORMAT_CHECK :=

ifeq ($(SYSTEM),Darwin)
PLATFORM_FORMAT := swift format --in-place --recursive Sources tests/CuotaXTests Package.swift
PLATFORM_FORMAT_CHECK := swift format lint --recursive Sources tests/CuotaXTests Package.swift
endif

.PHONY: build disable enable format format-check install lint test uninstall verify

lint:
	npm run lint

format:
	npm run format
	$(PLATFORM_FORMAT)

format-check:
	npm run format:check
	$(PLATFORM_FORMAT_CHECK)

ifeq ($(SYSTEM),Darwin)

build:
	scripts/build-macos-app.sh

test:
	swift test

verify: build
	codesign --verify --deep --strict --verbose=2 dist/CuotaX.app
	plutil -lint dist/CuotaX.app/Contents/Info.plist

install: build
	@pkill -x CuotaX >/dev/null 2>&1 || true
	@case "$(MACOS_APP)" in */Applications/CuotaX.app) ;; *) echo "Refusing to remove unexpected path: $(MACOS_APP)" >&2; exit 1;; esac
	rm -rf "$(MACOS_APP)"
	mkdir -p "$(dir $(MACOS_APP))"
	ditto "dist/CuotaX.app" "$(MACOS_APP)"
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
	scripts/pack-gnome-extension.sh

test:
	node --check $(EXTENSION_DIR)/backend.js
	node --check $(EXTENSION_DIR)/extension.js
	node --check $(EXTENSION_DIR)/quota.js
	gjs -m tests/gjs/test_quota.js
	CODEX_TEST_COMMAND="$(CURDIR)/tests/fixtures/codex" gjs -m tests/gjs/test_backend.js

verify: build
	unzip -t "$(ARCHIVE)"

install: build
	gnome-extensions install --force "$(ARCHIVE)"
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
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-windows.ps1

test:
	dotnet run --project tests/CuotaX.Windows.Tests/CuotaX.Windows.Tests.csproj --configuration Release

verify: build
	powershell.exe -NoProfile -Command "if (-not (Test-Path -LiteralPath 'dist/windows/CuotaX.exe')) { exit 1 }"

install:
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install-windows.ps1

uninstall:
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/uninstall-windows.ps1

enable disable:
	@echo "$@ is only available for the GNOME Shell extension" >&2
	@exit 1

else

build install test uninstall enable disable verify:
	@echo "Unsupported platform: $(SYSTEM)" >&2
	@exit 1

endif
