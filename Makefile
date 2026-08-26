UUID := cuotax@jpnurmi.github.com
EXTENSION_DIR := src
ARCHIVE := dist/$(UUID).shell-extension.zip

.PHONY: build disable enable format format-check install lint test uninstall

build:
	scripts/pack-gnome-extension.sh

lint:
	npm run lint

format:
	npm run format

format-check:
	npm run format:check

test:
	node --check $(EXTENSION_DIR)/backend.js
	node --check $(EXTENSION_DIR)/extension.js
	node --check $(EXTENSION_DIR)/quota.js
	gjs -m tests/gjs/test_quota.js
	CODEX_TEST_COMMAND="$(CURDIR)/tests/fixtures/codex" gjs -m tests/gjs/test_backend.js

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
