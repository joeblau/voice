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
#   MICROBENCH_FILTER   regular expression: only the matching benchmarks
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
        # package-benchmark's exit codes (BenchmarkShared.ExitCode).
        case $status in
            0)
                echo "microbench: every gated metric is within its threshold."
                ;;
            4)
                echo "microbench: faster than the thresholds; run 'make microbench-baseline' to tighten them."
                status=0
                ;;
            2)
                echo "microbench: REGRESSION: a gated metric is more than its tolerance worse than Thresholds/." >&2
                status=1
                ;;
            *)
                echo "microbench: the benchmark run failed (exit $status)." >&2
                status=1
                ;;
        esac
        exit "$status"
        ;;
    *)
        echo "usage: $0 run|check|update [package-benchmark options]" >&2
        exit 64
        ;;
esac
