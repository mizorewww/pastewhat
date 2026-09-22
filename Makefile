# PasteWhat — build, install, evaluation, and development helpers.
# Requires: macOS on Apple silicon, Swift 6 toolchain, python3.
# Optional: ruff (lint/format), uv (engine install).

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

APP_NAME    := PasteWhat
APP_BUNDLE  := dist/$(APP_NAME).app
INSTALL_DIR ?= $(HOME)/Applications

BACKEND     ?= mlx
MODEL       ?=
USE_SIBLING ?=
SUPPORT_DIR ?= $(HOME)/Library/Application Support/PasteWhat
ENGINE_JSON := $(SUPPORT_DIR)/engine.json

PY_SOURCES  := engine evaluations

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build release app into dist/PasteWhat.app (ad-hoc signed)
	./scripts/build-app.sh release

.PHONY: debug
debug: ## Build debug app into dist/PasteWhat.app
	./scripts/build-app.sh debug

.PHONY: install
install: build ## Install the app to INSTALL_DIR (default ~/Applications)
	@mkdir -p "$(INSTALL_DIR)"
	@pkill -x $(APP_NAME) 2>/dev/null || true
	ditto "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Run: open \"$(INSTALL_DIR)/$(APP_NAME).app\""

.PHONY: uninstall
uninstall: ## Remove the installed app from INSTALL_DIR
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Removed: $(INSTALL_DIR)/$(APP_NAME).app"

.PHONY: run
run: build ## Build and launch the app
	open "$(APP_BUNDLE)"

.PHONY: demo
demo: build ## Build and launch the isolated UI demo (no real history)
	open -n "$(APP_BUNDLE)" --args --demo

.PHONY: setup-engine
setup-engine: ## Install Laya engine (BACKEND=mlx|coreml MODEL=/path USE_SIBLING=1)
	@args=(--backend "$(BACKEND)" --support-dir "$(SUPPORT_DIR)"); \
	if [ -n "$(MODEL)" ]; then args+=(--model "$(MODEL)"); fi; \
	if [ -n "$(USE_SIBLING)" ]; then args+=(--use-sibling); fi; \
	./scripts/setup-engine.sh "$${args[@]}"

.PHONY: signing-identity
signing-identity: ## Create a persistent local signing identity so privacy grants survive rebuilds
	./scripts/create-signing-identity.sh

NOTARY_PROFILE ?= pastewhat-notary
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

.PHONY: notary-profile
notary-profile: ## Store notarization credentials (KEY=/path/AuthKey.p8 KEY_ID=... ISSUER=...)
	@test -n "$(KEY)" -a -n "$(KEY_ID)" -a -n "$(ISSUER)" || { echo "Usage: make notary-profile KEY=/path/AuthKey_XXXX.p8 KEY_ID=... ISSUER=..." >&2; exit 2; }
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --key "$(KEY)" --key-id "$(KEY_ID)" --issuer "$(ISSUER)"

# Distribution builds set PASTEWHAT_DIST=1 so the developer's workspace path
# is not embedded in the published Info.plist.
.PHONY: notarize
notarize: ## Build (distribution mode), notarize, and staple the app (uses NOTARY_PROFILE)
	PASTEWHAT_DIST=1 ./scripts/build-app.sh release
	ditto -c -k --keepParent "$(APP_BUNDLE)" dist/PasteWhat.zip
	xcrun notarytool submit dist/PasteWhat.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	rm dist/PasteWhat.zip
	@echo "Notarized: $(APP_BUNDLE)"

.PHONY: release
release: notarize ## Package the notarized app as dist/PasteWhat-VERSION.zip (+ sha256)
	ditto -c -k --keepParent "$(APP_BUNDLE)" "dist/$(APP_NAME)-$(VERSION).zip"
	shasum -a 256 "dist/$(APP_NAME)-$(VERSION).zip" > "dist/$(APP_NAME)-$(VERSION).zip.sha256"
	@echo "Release artifact: dist/$(APP_NAME)-$(VERSION).zip"
	@cat "dist/$(APP_NAME)-$(VERSION).zip.sha256"

.PHONY: lint
lint: ## Ruff lint + shell script syntax check
	ruff check $(PY_SOURCES)
	bash -n scripts/*.sh

.PHONY: format
format: ## Auto-format Python sources with ruff
	ruff format $(PY_SOURCES)

.PHONY: fix
fix: ## Auto-fix Python lint findings with ruff
	ruff check --fix $(PY_SOURCES)

.PHONY: check
check: ## Fast verification: swift build, ruff, python syntax, shell syntax
	swift build
	ruff check $(PY_SOURCES)
	python3 -m compileall -q engine evaluations
	bash -n scripts/*.sh
	@echo "check: OK"

.PHONY: evaluate
evaluate: ## Run the frozen recommendation evaluation (reads engine.json)
	@test -f "$(ENGINE_JSON)" || { echo "No engine.json. Run 'make setup-engine' first." >&2; exit 1; }
	@IFS=$$'\t' read -r PY MODEL ENGBACKEND <<< "$$(python3 -c 'import json; c = json.load(open("$(ENGINE_JSON)")); print(c["pythonPath"], c.get("modelPath", ""), c["backend"], sep="\t")')"; \
	COMMIT=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown); \
	args=(--python "$$PY" --worker engine/worker.py --backend "$$ENGBACKEND" \
	      --protocol current --split all --label "make-$$COMMIT-$$(date +%Y%m%d-%H%M%S)" \
	      --production-commit "$$COMMIT"); \
	if [ -n "$$MODEL" ]; then args+=(--model "$$MODEL"); fi; \
	python3 evaluations/run.py "$${args[@]}"

.PHONY: clean
clean: ## Remove swift build artifacts and the packaged app
	rm -rf .build dist
