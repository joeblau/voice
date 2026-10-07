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

.PHONY: perf
perf: generate ## Run performance tests (Blau-Perf scheme, Release)
	$(XCODEBUILD) test -scheme Blau-Perf -testPlan BlauPerf -destination '$(DESTINATION)' $(SIM_FLAGS)

.PHONY: clean
clean: ## Remove the generated project, plists and DerivedData
	rm -rf $(PROJECT) $(DERIVED_DATA) Blau/Supporting
