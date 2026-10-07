# Blau developer tasks. The Xcode project is generated from project.yml by
# XcodeGen and is never committed: run `make generate` after every pull.
#
# Overridable variables:
#   DESTINATION        xcodebuild destination for test runs, e.g.
#                      DESTINATION='id=<simulator udid>'
#   BUILD_DESTINATION  xcodebuild destination for `make build`
#   DERIVED_DATA       DerivedData location (kept inside the repo)

PROJECT           := Blau.xcodeproj
DERIVED_DATA      ?= .build/DerivedData
DESTINATION       ?= platform=iOS Simulator,name=iPhone 17,OS=latest
BUILD_DESTINATION ?= generic/platform=iOS Simulator

XCODEGEN   ?= xcodegen
XCODEBUILD := xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED_DATA)
SIM_FLAGS  := CODE_SIGNING_ALLOWED=NO

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available tasks
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: generate
generate: ## Generate Blau.xcodeproj from project.yml
	@command -v $(XCODEGEN) >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	$(XCODEGEN) generate

.PHONY: open
open: generate ## Generate and open the project in Xcode
	open $(PROJECT)

.PHONY: build
build: generate ## Build the app for the iOS Simulator (Debug)
	$(XCODEBUILD) build -scheme Blau -destination '$(BUILD_DESTINATION)' $(SIM_FLAGS)

.PHONY: test
test: generate ## Run unit + UI tests (Blau scheme, Blau test plan, coverage on)
	$(XCODEBUILD) test -scheme Blau -testPlan Blau -destination '$(DESTINATION)' $(SIM_FLAGS)

.PHONY: test-unit
test-unit: generate ## Run only the unit tests
	$(XCODEBUILD) test -scheme Blau -testPlan Blau -only-testing:BlauTests -destination '$(DESTINATION)' $(SIM_FLAGS)

.PHONY: test-ui
test-ui: generate ## Run only the UI tests
	$(XCODEBUILD) test -scheme Blau -testPlan Blau -only-testing:BlauUITests -destination '$(DESTINATION)' $(SIM_FLAGS)

.PHONY: test-kit
test-kit: ## Run the BlauKit package tests on the macOS host
	cd Packages/BlauKit && swift test

.PHONY: perf
perf: generate ## Run performance tests (Blau-Perf scheme, Release)
	$(XCODEBUILD) test -scheme Blau-Perf -testPlan BlauPerf -destination '$(DESTINATION)' $(SIM_FLAGS) XAI_DEV_API_KEY=

.PHONY: secrets
secrets: ## Create Config/Secrets.xcconfig from the example (kept if it exists)
	scripts/write-secrets-xcconfig.sh

.PHONY: test-scripts
test-scripts: ## Test the secrets build scripts
	scripts/tests/test-secrets-scripts.sh

.PHONY: clean
clean: ## Remove the generated project, plists and DerivedData
	rm -rf $(PROJECT) $(DERIVED_DATA) Blau/Supporting

# Formatting and lint. Both run swift-format with the repo-root .swift-format
# config over every Swift file git tracks or would track (see
# scripts/swift-format.sh). Override the tool with SWIFT_FORMAT="swift format".

.PHONY: format
format: ## Format all Swift sources in place with swift-format
	@scripts/swift-format.sh format

.PHONY: lint
lint: ## Lint all Swift sources with swift-format (every finding is an error)
	@scripts/swift-format.sh lint

.PHONY: hooks
hooks: ## Install the optional pre-commit hook (lints staged Swift files)
	git config core.hooksPath scripts/git-hooks
	@echo "Installed. Skip once with 'git commit --no-verify'; remove with 'make unhooks'."

.PHONY: unhooks
unhooks: ## Remove the pre-commit hook installed by `make hooks`
	-git config --unset core.hooksPath
