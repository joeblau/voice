#!/bin/sh
# BlauKit micro-benchmarks (#73): ordo-one's package-benchmark over the
# pure-Swift hot paths (topic engine, RRF, int8 vector search) in
# Packages/BlauKitBenchmarks, on the macOS host. Behind `make microbench`,
# `make microbench-check` and `make microbench-baseline`, and the `perf-kit`
# CI job. See docs/performance.md, "Micro-benchmarks".
#
# Usage: scripts/perf/microbench.sh run|check|update|compare [args]
#
#   run            run every benchmark and print the results
#   check          run them and compare each gated metric's p90 with the
#                  committed thresholds in Packages/BlauKitBenchmarks/Thresholds:
#                  exit 0 when within tolerance (10%), 1 on a regression. A
#                  result *better* than the tolerance also passes, with a
#                  notice to tighten the thresholds.
#   update         run them and rewrite the thresholds from this run (commit
#                  the result; see docs/performance.md for when to)
#   compare <ref>  run them on this tree and on BlauKit's sources at <ref>
#                  (for example origin/main) on this machine, and fail when
#                  this tree is more than 10% worse in a gated metric
#                  (allocations; instructions on a Mac that counts them). For
#                  before/after checks during development, where the
#                  committed thresholds come from another toolchain. Prints
#                  the CPU-time difference too, which isn't gated. Exits 0
#                  with a notice when <ref> doesn't build.
#
# Environment:
#   MICROBENCH_FILTER   regular expression matching whole benchmark names,
#                       e.g. "memory\..+": only those benchmarks
#   MICROBENCH_OUTPUT   file the check's report is also written to (CI puts
#                       it on the job summary)

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
package="$repo/Packages/BlauKitBenchmarks"
kit_sources="$repo/Packages/BlauKit/Sources"
command=${1:-run}
[ $# -gt 0 ] && shift

options="--no-progress"
if [ -n "${MICROBENCH_FILTER:-}" ]; then
    options="$options --filter $MICROBENCH_FILTER"
fi

report=$(mktemp "${TMPDIR:-/tmp}/microbench.XXXXXX")
work=""
cleanup() {
    rm -f "$report"
    if [ -n "$work" ]; then
        # Put this tree's BlauKit sources back if a comparison swapped them.
        if [ -d "$work/this-sources" ]; then
            rm -rf "$kit_sources"
            mv "$work/this-sources" "$kit_sources"
        fi
        rm -rf "$work"
    fi
}
trap cleanup EXIT
# An interrupted comparison still puts the sources back.
trap 'exit 130' INT TERM HUP

# Runs package-benchmark with the arguments given, saving its output in
# $report (and MICROBENCH_OUTPUT), and sets $status.
benchmark() {
    status=0
    # shellcheck disable=SC2086 # $options is a word list on purpose.
    (cd "$package" && swift package "$@" $options) >"$report" 2>&1 || status=$?
    cat "$report"
    if [ -n "${MICROBENCH_OUTPUT:-}" ]; then
        mkdir -p "$(dirname -- "$MICROBENCH_OUTPUT")"
        cat "$report" >>"$MICROBENCH_OUTPUT"
    fi
}

# Turns the last benchmark()'s outcome into this script's exit status. The
# tool exits 2 on a regression and 4 on an improvement
# (BenchmarkShared.ExitCode), but `swift package` turns any plugin error
# into exit 1 and prints the plugin's error name, so classify by the name.
verdict() {
    if [ "$status" -eq 0 ]; then
        echo "microbench: every gated metric is within its tolerance."
        exit 0
    elif grep -q 'benchmarkThresholdRegression' "$report" || [ "$status" -eq 2 ]; then
        echo "microbench: REGRESSION: a gated metric is more than its tolerance worse than $1." >&2
        exit 1
    elif grep -q 'benchmarkThresholdImprovement' "$report" || [ "$status" -eq 4 ]; then
        echo "microbench: better than $1; run 'make microbench-baseline' to tighten the thresholds."
        exit 0
    fi
    echo "microbench: the benchmark run failed (exit $status)." >&2
    exit 1
}

if [ -n "${MICROBENCH_OUTPUT:-}" ]; then
    mkdir -p "$(dirname -- "$MICROBENCH_OUTPUT")"
    : >"$MICROBENCH_OUTPUT"
fi

case $command in
    run)
        benchmark benchmark "$@"
        exit "$status"
        ;;
    update)
        benchmark --allow-writing-to-package-directory benchmark thresholds update --path Thresholds "$@"
        exit "$status"
        ;;
    check)
        benchmark benchmark thresholds check --path Thresholds "$@"
        verdict "the committed thresholds (Thresholds/)"
        ;;
    compare)
        base=${1:?usage: $0 compare <git ref>}
        work=$(mktemp -d "${TMPDIR:-/tmp}/microbench-compare.XXXXXX")
        if ! git -C "$repo" archive "$base" Packages/BlauKit/Sources | tar -x -C "$work"; then
            echo "microbench: can't read BlauKit's sources at $base" >&2
            exit 1
        fi
        benchmark --allow-writing-to-package-directory benchmark baseline update this-tree
        [ "$status" -eq 0 ] || verdict "this tree"
        # The base's sources in place of this tree's, benchmarks unchanged.
        mv "$kit_sources" "$work/this-sources"
        mv "$work/Packages/BlauKit/Sources" "$kit_sources"
        benchmark --allow-writing-to-package-directory benchmark baseline update base
        base_status=$status
        rm -rf "$kit_sources"
        mv "$work/this-sources" "$kit_sources"
        if [ "$base_status" -ne 0 ]; then
            echo "microbench: the benchmarks don't build or run at $base; skipping the comparison."
            exit 0
        fi
        benchmark benchmark baseline check base this-tree
        verdict "$base on this machine"
        ;;
    *)
        echo "usage: $0 run|check|update|compare <ref> [package-benchmark options]" >&2
        exit 64
        ;;
esac
