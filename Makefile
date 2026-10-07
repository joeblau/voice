# Blau developer tasks. The Xcode project is generated from project.yml by
# XcodeGen and is never committed: run `make generate` after every pull.
#
# Overridable variables:
#   DESTINATION        xcodebuild destination for test runs, e.g.
#                      DESTINATION='id=<simulator udid>'
#   BUILD_DESTINATION  xcodebuild destination for `make build`
#   DERIVED_DATA       DerivedData location (kept inside the repo)
#   XCODEBUILD_FLAGS   Extra xcodebuild arguments, e.g. CI's
#                      XCODEBUILD_FLAGS='-resultBundlePath .build/results/app.xcresult'

PROJECT           := Blau.xcodeproj
DERIVED_DATA      ?= .build/DerivedData
DESTINATION       ?= platform=iOS Simulator,name=iPhone 17,OS=latest
BUILD_DESTINATION ?= generic/platform=iOS Simulator
XCODEBUILD_FLAGS  ?=

XCODEGEN   ?= xcodegen
XCODEBUILD := xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED_DATA) $(XCODEBUILD_FLAGS)
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

# On-device model benchmarks (#22): a physical iPhone (DEVICE=<udid> from
# `xcrun devicectl list devices`) with signing set up. Results land in the
# .xcresult as attachments; see docs/benchmarks.md.
BENCH_RESULT ?= .build/Benchmarks/$(shell date +%Y%m%d-%H%M%S).xcresult

.PHONY: bench
bench: generate ## Run the model benchmarks on DEVICE=<udid> (Release, docs/benchmarks.md)
	@test -n "$(DEVICE)" || { echo "Set DEVICE=<udid>; list devices with: xcrun devicectl list devices"; exit 1; }
	TEST_RUNNER_BLAU_DEVICE_TESTS=1 $(XCODEBUILD) test -scheme Blau-Benchmarks -testPlan BlauBenchmarks \
		-destination 'id=$(DEVICE)' -resultBundlePath '$(BENCH_RESULT)' -allowProvisioningUpdates

.PHONY: bench-kit
bench-kit: ## Run the model benchmarks on this Mac (reference numbers only, downloads models)
	cd Packages/BlauKit && BLAU_DEVICE_TESTS=1 swift test -c release --filter RealModel

.PHONY: secrets
secrets: ## Create Config/Secrets.xcconfig from the example (kept if it exists)
	env -u XAI_DEV_API_KEY scripts/write-secrets-xcconfig.sh

.PHONY: test-scripts
test-scripts: ## Test the secrets, CI and Instruments template scripts
	scripts/tests/test-secrets-scripts.sh
	scripts/tests/test-ci-scripts.sh
	scripts/tests/test-instruments-template.sh

# Instruments template (Tools/Instruments; see docs/performance.md).
#   TRACE_DEVICE  device name or UDID for `make trace`

INSTRUMENTS_TEMPLATE      := Tools/Instruments/Blau.tracetemplate
INSTRUMENTS_TEMPLATES_DIR ?= $(HOME)/Library/Application Support/Instruments/Templates
TRACE_DEVICE              ?=

.PHONY: instruments-template
instruments-template: ## Regenerate the Blau Instruments template from Tools/Instruments
	scripts/make-instruments-template.sh

.PHONY: verify-instruments
verify-instruments: ## Record with the Blau template on the Mac and check every interval is captured
	scripts/verify-instruments-template.sh

.PHONY: install-instruments-template
install-instruments-template: ## Add the Blau template to Instruments' template chooser
	mkdir -p "$(INSTRUMENTS_TEMPLATES_DIR)"
	cp $(INSTRUMENTS_TEMPLATE) "$(INSTRUMENTS_TEMPLATES_DIR)/Blau.tracetemplate"

.PHONY: trace
trace: ## Record the running Blau app on TRACE_DEVICE with the Blau template
	@test -n "$(TRACE_DEVICE)" || { echo "Set TRACE_DEVICE to a device name or UDID (xcrun xctrace list devices)"; exit 1; }
	mkdir -p .build/traces
	xcrun xctrace record --template $(INSTRUMENTS_TEMPLATE) --device '$(TRACE_DEVICE)' \
		--attach Blau --output .build/traces/

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
