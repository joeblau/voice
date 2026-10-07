#!/bin/sh
# BlauKit micro-benchmarks (#73): ordo-one's package-benchmark over the
# pure-Swift hot paths (topic engine, RRF, int8 vector search) in
# Packages/BlauKitBenchmarks, on the macOS host. Behind `make microbench`,
# `make microbench-check` and `make microbench-baseline`, and the `perf-kit`
# CI job. See docs/performance.md, "Micro-benchmarks".
#
# Usage: scripts/perf/microbench.sh run|check|update [package-benchmark options]
#
#   run     run every benchmark and print the results
#   check   run them and compare each gated metric's p90 with the committed
#           thresholds in Packages/BlauKitBenchmarks/Thresholds: exit 0 when
#           within tolerance (10%), 1 on a regression. A result that is
#           *better* than the tolerance also passes, with a notice to
#           tighten the thresholds (package-benchmark itself exits 4 then).
#   update  run them and rewrite the thresholds from this run (commit the
#           result; see docs/performance.md for when to)
#
# Environment:
#   MICROBENCH_FILTER   regular expression matching whole benchmark names,
#                       e.g. "memory\..+": only those benchmarks
#   MICROBENCH_OUTPUT   file the check's report is also written to (CI puts
#                       it on the job summary)

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
package="$repo/Packages/BlauKitBenchmarks"
command=${1:-run}
[ $# -gt 0 ] && shift

set -- "$@" --no-progress
if [ -n "${MICROBENCH_FILTER:-}" ]; then
    set -- "$@" --filter "$MICROBENCH_FILTER"
fi

cd "$package"
case $command in
    run)
        exec swift package benchmark "$@"
        ;;
    update)
        exec swift package --allow-writing-to-package-directory benchmark thresholds update --path Thresholds "$@"
        ;;
    check)
        output=${MICROBENCH_OUTPUT:-}
        report=$(mktemp "${TMPDIR:-/tmp}/microbench.XXXXXX")
        trap 'rm -f "$report"' EXIT
        status=0
        swift package benchmark thresholds check --path Thresholds "$@" >"$report" 2>&1 || status=$?
        cat "$report"
        if [ -n "$output" ]; then
            mkdir -p "$(dirname -- "$output")"
            cp "$report" "$output"
        fi
        # The tool exits 2 on a regression and 4 on an improvement
        # (BenchmarkShared.ExitCode), but `swift package` turns any plugin
        # error into exit 1 and prints the plugin's error name, so classify
        # by that name.
        if [ "$status" -eq 0 ]; then
            outcome=equal
        elif grep -q 'benchmarkThresholdRegression' "$report" || [ "$status" -eq 2 ]; then
            outcome=regression
        elif grep -q 'benchmarkThresholdImprovement' "$report" || [ "$status" -eq 4 ]; then
            outcome=improvement
        else
            outcome=failed
        fi
        case $outcome in
            equal)
                echo "microbench: every gated metric is within its threshold."
                exit 0
                ;;
            improvement)
                echo "microbench: faster than the thresholds; run 'make microbench-baseline' to tighten them."
                exit 0
                ;;
            regression)
                echo "microbench: REGRESSION: a gated metric is more than its tolerance worse than Thresholds/." >&2
                exit 1
                ;;
            *)
                echo "microbench: the benchmark run failed (exit $status)." >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "usage: $0 run|check|update [package-benchmark options]" >&2
        exit 64
        ;;
esac
