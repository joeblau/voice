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
#   UI_SHARD           K/N: `make test-ui` runs only the K-th of N slices of
#                      the UI tests (scripts/ci/ui-test-shard.sh), as CI does
#   UI_TEST_SUITE      all (default), functional, or performance

PROJECT           := Blau.xcodeproj
DERIVED_DATA      ?= .build/DerivedData
DESTINATION       ?= platform=iOS Simulator,name=iPhone 17,OS=latest
BUILD_DESTINATION ?= generic/platform=iOS Simulator
XCODEBUILD_FLAGS  ?=
UI_SHARD          ?=
UI_TEST_SUITE     ?= all

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

.PHONY: build-tests
build-tests: generate ## Build the app and the Blau test plan's test bundles for DESTINATION without testing
	$(XCODEBUILD) build-for-testing -scheme Blau -testPlan Blau -destination '$(DESTINATION)' $(SIM_FLAGS)

.PHONY: test-unit
test-unit: generate ## Run only the unit tests
	$(XCODEBUILD) test -scheme Blau -testPlan Blau -only-testing:BlauTests -destination '$(DESTINATION)' $(SIM_FLAGS)

# With UI_SHARD=K/N, only the K-th of N slices of BlauUITests: CI runs the N
# slices as parallel jobs (docs/ci.md). The selection is computed first so a
# failure stops here instead of running the whole test plan.
.PHONY: test-ui
test-ui: generate ## Run only the UI tests (UI_SHARD=K/N: one of N slices, as CI)
	@set -e; \
	if [ -n '$(UI_SHARD)' ] || [ '$(UI_TEST_SUITE)' != all ]; then \
		selection=$$(UI_TEST_SUITE='$(UI_TEST_SUITE)' scripts/ci/ui-test-shard.sh '$(or $(UI_SHARD),1/1)'); \
		echo "UI tests ($(UI_TEST_SUITE)), shard $(or $(UI_SHARD),1/1): $$(echo "$$selection" | wc -l | tr -d ' ') tests"; \
	else \
		selection=-only-testing:BlauUITests; \
	fi; \
	set -x; \
	$(XCODEBUILD) test -scheme Blau -testPlan Blau $$selection -destination '$(DESTINATION)' $(SIM_FLAGS)

.PHONY: test-kit
test-kit: ## Run the BlauKit package tests on the macOS host
	cd Packages/BlauKit && swift test

# XCTest performance suite (#73): launch metrics and the scripted five-minute
# session, in Release with the BLAU_PERF condition (which compiles the replay
# into the app), for the active architecture only. The result bundle goes to
# PERF_RESULT; `make perf-check` compares it with the committed baseline for
# PERF_BASELINE (BlauPerfTests/Baselines/<name>.json). See
# docs/performance.md, "Performance suite".
PERF_RESULT   ?= .build/results/perf.xcresult
PERF_BASELINE ?= ci-simulator
PERF_REPORT   ?= .build/results/perf-report.md
PERF_RESULTS  ?= .build/results/perf-results.json
PERF_FLAGS    := 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$$(inherited) BLAU_PERF' ONLY_ACTIVE_ARCH=YES

.PHONY: build-perf-tests
build-perf-tests: generate ## Build the Release app and performance/soak test bundles before booting a simulator
	$(XCODEBUILD) build-for-testing -scheme Blau-Perf -testPlan BlauPerf -destination '$(DESTINATION)' \
		$(SIM_FLAGS) $(PERF_FLAGS) XAI_DEV_API_KEY=

.PHONY: perf
perf: generate ## Run performance tests (Blau-Perf scheme, Release + BLAU_PERF) into PERF_RESULT
	rm -rf '$(PERF_RESULT)'
	$(XCODEBUILD) test -scheme Blau-Perf -testPlan BlauPerf -destination '$(DESTINATION)' \
		-resultBundlePath '$(PERF_RESULT)' $(SIM_FLAGS) $(PERF_FLAGS) XAI_DEV_API_KEY=

.PHONY: perf-check
perf-check: ## Compare PERF_RESULT with the PERF_BASELINE baseline; fails on a >10% regression
	scripts/perf/perf-gate.py check --xcresult '$(PERF_RESULT)' \
		--baseline BlauPerfTests/Baselines/$(PERF_BASELINE).json --report '$(PERF_REPORT)' \
		--results-output '$(PERF_RESULTS)'

.PHONY: perf-baseline
perf-baseline: ## Record PERF_RESULT as the PERF_BASELINE baseline (commit it)
	scripts/perf/perf-gate.py record --xcresult '$(PERF_RESULT)' \
		--baseline BlauPerfTests/Baselines/$(PERF_BASELINE).json --environment $(PERF_BASELINE)

# Long-session soak test (#76): the BlauSoak test plan (BlauPerfTests/SoakTests)
# in Release with the BLAU_PERF condition. Plays SOAK_MINUTES of mixed audio
# (the user, a TV, silence) through the app's pipeline at SOAK_SPEED against a
# local fake realtime server, and on a simulator reads the app's leaks during
# and after the run. The report and leak readings land in SOAK_OUTPUT. See
# scripts/soak/soak.sh and docs/soak.md.
SOAK_MINUTES ?= 120
SOAK_SPEED   ?= 10
SOAK_ASR     ?= scripted
SOAK_OUTPUT  ?= .build/results/soak

.PHONY: soak
soak: generate ## Run the long-session soak test: SOAK_MINUTES (120) of audio at SOAK_SPEED (10x), plus leaks
	DESTINATION='$(DESTINATION)' DERIVED_DATA='$(DERIVED_DATA)' XCODEBUILD_FLAGS='$(XCODEBUILD_FLAGS)' \
		SOAK_MINUTES='$(SOAK_MINUTES)' SOAK_SPEED='$(SOAK_SPEED)' SOAK_ASR='$(SOAK_ASR)' \
		SOAK_OUTPUT='$(SOAK_OUTPUT)' scripts/soak/soak.sh

# BlauKit micro-benchmarks (#73): package-benchmark in Packages/BlauKitBenchmarks
# on this Mac. The check gates instructions and allocations at 10% against
# Packages/BlauKitBenchmarks/Thresholds. See scripts/perf/microbench.sh.
.PHONY: microbench
microbench: ## Run the BlauKit micro-benchmarks (topic engine, RRF, int8 search) on this Mac
	scripts/perf/microbench.sh run

.PHONY: microbench-check
microbench-check: ## Run the micro-benchmarks and fail on a >10% regression against Thresholds/
	scripts/perf/microbench.sh check

.PHONY: microbench-compare
microbench-compare: ## Compare the micro-benchmarks with BlauKit at BASE (default origin/main) on this Mac
	scripts/perf/microbench.sh compare $(or $(BASE),origin/main)

.PHONY: microbench-baseline
microbench-baseline: ## Rewrite the micro-benchmark thresholds from a run on this Mac (commit them)
	scripts/perf/microbench.sh update

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

# ASR evaluation harness (#32): WER, first-partial and end-of-utterance
# latency and RTF of every engine on the ASR fixtures (Git LFS), with the
# regression gate in docs/asr-eval/thresholds.json. Downloads the pinned
# models into ASR_EVAL_MODELS (default .build/models) on first use. The other
# ASR_EVAL_* variables are documented in scripts/eval-asr.sh and
# docs/asr-eval.md.
.PHONY: eval-asr
eval-asr: ## Evaluate the ASR engines on the fixtures: a WER/latency/RTF table per engine (docs/asr-eval.md)
	scripts/eval-asr.sh

# Noise suppression A/B (#51): the ASR engines alone and behind DeepFilterNet3
# and Apple's AUSoundIsolation, plus each suppressor's cost. Variables in
# scripts/eval-noise-suppression.sh.
.PHONY: eval-noise
eval-noise: ## Compare noise suppressors on the ASR fixtures: WER and cost (docs/noise-suppression.md)
	scripts/eval-noise-suppression.sh

# Memory evaluation (#70): Recall@k and MRR of hybrid retrieval on the memory
# eval set, plus LLM-judged answer accuracy where Apple's on-device model can
# run, with the regression gate in docs/memory-eval/thresholds.json. Text
# only; the MEMORY_EVAL_* variables are documented in scripts/eval-memory.sh
# and docs/memory-eval.md.
.PHONY: eval-memory
eval-memory: ## Evaluate memory retrieval and answers on the memory eval set (docs/memory-eval.md)
	scripts/eval-memory.sh

# App icon previews (#82): every iOS appearance of Blau/Resources/AppIcon.icon,
# rendered with Icon Composer's ictool into .build/AppIcon (docs/branding.md).
.PHONY: icon-previews
icon-previews: ## Render the app icon in every appearance into .build/AppIcon (docs/branding.md)
	scripts/render-app-icon.sh

# TestFlight release pipeline (#83, docs/release.md). Both need TEAM_ID and
# BUILD_NUMBER; uploading also needs the App Store Connect API key
# (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH). The other variables are
# documented in scripts/release/testflight.sh. CI runs `make testflight` from
# .github/workflows/release.yml on every v* tag.
.PHONY: testflight
testflight: ## Archive (Release), export, verify and upload to TestFlight (TEAM_ID, BUILD_NUMBER, ASC_KEY_*)
	scripts/release/testflight.sh

.PHONY: release-archive
release-archive: ## Archive, export and verify a TestFlight IPA into .build/release without uploading
	UPLOAD=0 scripts/release/testflight.sh

.PHONY: release-notes
release-notes: ## Print release notes for the pull requests merged since the last v* tag
	scripts/release/release.py notes

.PHONY: secrets
secrets: ## Create Config/Secrets.xcconfig from the example (kept if it exists)
	env -u XAI_DEV_API_KEY scripts/write-secrets-xcconfig.sh

.PHONY: test-scripts
test-scripts: ## Test the secrets, CI, Instruments template, perf gate, privacy manifest, release and soak scripts
	scripts/tests/test-secrets-scripts.sh
	scripts/tests/test-ci-scripts.sh
	scripts/tests/test-instruments-template.sh
	scripts/tests/test-perf-gate.sh
	scripts/tests/test-privacy-manifest.sh
	scripts/tests/test-release-scripts.sh
	scripts/tests/test-soak-scripts.sh

# Privacy manifests (#79, docs/privacy.md). PRIVACY_BUNDLE: a built Blau.app
# or a Blau .xcarchive to check as well.
.PHONY: check-privacy
check-privacy: ## Validate the privacy manifests and that the sources' required-reason APIs are declared
	scripts/check-privacy-manifest.py
	$(if $(PRIVACY_BUNDLE),scripts/check-privacy-manifest.py bundle '$(PRIVACY_BUNDLE)')

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

.PHONY: verify-hud
verify-hud: ## Record a HUD workload on the Mac and check the HUD's numbers match Instruments
	scripts/verify-hud.sh

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
