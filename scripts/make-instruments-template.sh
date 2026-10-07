#!/usr/bin/env bash
#
# Regenerates Tools/Instruments/Blau.tracetemplate.
#
# The template is a binary NSKeyedArchiver file that only Instruments can
# write, so instead of hand-editing it this script has xctrace build it:
#
#   1. Records a two-second trace of a stand-in process on the Mac with every
#      instrument in Tools/Instruments/instruments.txt and the options in
#      Tools/Instruments/recording-options.json.
#   2. Takes the template xctrace stores inside the trace (form.template),
#      drops the recorded run and symbol stores and sets the description
#      (scripts/lib/tracetemplate.py).
#
# The result is the same file Instruments writes with File > Save as
# Template. Edit instruments.txt or recording-options.json, run this, and
# commit the three files together. scripts/verify-instruments-template.sh
# then checks a recording with the new template.
#
# Usage:
#   scripts/make-instruments-template.sh [output.tracetemplate]
#
# Requires Xcode (xctrace, clang) and python3.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
dir="$root/Tools/Instruments"
out="${1:-$dir/Blau.tracetemplate}"
lib="$root/scripts/lib"
description="Blau: BlauTelemetry signposts and logs (subsystem com.joeblau.blau), \
Audio System Trace, Hangs, Allocations, Core ML and Neural Engine, Foundation Models, \
Network and Thermal State. Profile a Release build of Blau and record a conversation."

work="$(mktemp -d "${TMPDIR:-/tmp}/blau-template.XXXXXX")"
trap 'rm -rf "$work"' EXIT

instrument_args=()
while IFS= read -r name; do
    instrument_args+=(--instrument "$name")
done < <(grep -v -E '^[[:space:]]*(#|$)' "$dir/instruments.txt")
[[ ${#instrument_args[@]} -gt 0 ]] || { echo "No instruments in $dir/instruments.txt" >&2; exit 1; }

echo "==> Building the stand-in target"
xcrun clang -O2 -o "$work/trace-target" "$lib/trace-target.c"
codesign --force --sign - --entitlements "$lib/trace-target.entitlements" "$work/trace-target" 2>/dev/null

record() {
    rm -rf "$work/template.trace"
    echo "==> Recording with $(( ${#instrument_args[@]} / 2 )) instruments"
    xcrun xctrace record --no-prompt "${instrument_args[@]}" \
        --recording-options "$dir/recording-options.json" \
        --time-limit 60s --output "$work/template.trace" \
        --launch -- "$work/trace-target" "$work/never" 2 >"$work/xctrace.log" 2>&1 \
        && [[ -f "$work/template.trace/form.template" ]] \
        && ! grep -q "\[Error\]" "$work/xctrace.log"
}

# The Xcode 27.2 beta's xctrace occasionally crashes while saving a
# recording, so try twice.
record || { echo "==> Retrying the recording once" >&2; record; } \
    || { echo "xctrace did not write a template" >&2; cat "$work/xctrace.log" >&2; exit 1; }

echo "==> Writing $out"
python3 -I "$lib/tracetemplate.py" template "$work/template.trace/form.template" "$out" "$description"

echo "==> Instruments in the template"
python3 -I "$lib/tracetemplate.py" instruments "$out" | sed 's/^/    /'
