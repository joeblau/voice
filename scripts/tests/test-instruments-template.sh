#!/bin/sh
# Tests for Tools/Instruments/Blau.tracetemplate and scripts/lib/tracetemplate.py.
# Hermetic: reads the committed template and synthetic fixtures; records
# nothing. When xctrace is available it also loads the template without
# recording. Run with `make test-scripts`.
#
# scripts/verify-instruments-template.sh is the end-to-end check: it records
# a trace with the template and checks every canonical interval is captured.

set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
lib="$root/scripts/lib/tracetemplate.py"
template="$root/Tools/Instruments/Blau.tracetemplate"
instruments="$root/Tools/Instruments/instruments.txt"
doc="$root/docs/performance.md"

work=$(mktemp -d "${TMPDIR:-/tmp}/blau-template-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# expect <description> <expected exit status> <command...>
expect() {
    description=$1
    expected=$2
    shift 2
    "$@" >"$work/out" 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (exit $actual, expected $expected)"
        sed 's/^/       /' "$work/out"
    fi
}

# expect_output <description> <fixed string> <command...>
expect_output() {
    description=$1
    needle=$2
    shift 2
    "$@" >"$work/out" 2>&1
    if grep -q -F -- "$needle" "$work/out"; then
        pass "$description"
    else
        fail "$description (no \"$needle\" in output)"
        sed 's/^/       /' "$work/out"
    fi
}

# --- the committed template ----------------------------------------------------

expect "template is a valid property list" 0 plutil -lint "$template"

expect "template has exactly the instruments in instruments.txt" 0 \
    python3 -I "$lib" check-instruments "$template" "$instruments"

for name in "os_signpost" "Points of Interest" "Audio Client" "Audio Server" "Audio Statistics" \
    "Hangs" "Allocations" "Core ML" "Foundation Models" "HTTP Traffic" "Network Connections" \
    "Thermal State"; do
    if grep -q -x -F "$name" "$instruments"; then
        pass "instruments.txt lists $name (issue #77)"
    else
        fail "instruments.txt lists $name (issue #77)"
    fi
done

expect_output "os_signpost enables dynamic tracing for com.joeblau.blau" "com.joeblau.blau" \
    python3 -I "$lib" signpost-subsystems "$template"

plutil -p "$template" >"$work/template.txt" 2>&1
if grep -q -E 'com\.apple\.xray\.run\.data|symbolstore|instruments-by-run-number' "$work/template.txt"; then
    fail "template carries no recorded run or symbol stores"
else
    pass "template carries no recorded run or symbol stores"
fi
if strings -a "$template" | grep -q -E '/(Users|private|var/folders|tmp)/'; then
    fail "template embeds no local paths"
else
    pass "template embeds no local paths"
fi
if grep -q -F "Blau: BlauTelemetry signposts" "$work/template.txt"; then
    pass "template has Blau's description"
else
    fail "template has Blau's description"
fi
size=$(wc -c <"$template" | tr -d ' ')
if [ "$size" -lt 102400 ]; then
    pass "template is small ($size bytes)"
else
    fail "template is small ($size bytes, expected < 100 KB)"
fi

# --- tracetemplate.py template -------------------------------------------------

# Re-running the cleaner over a template is lossless: same instruments,
# same options, new description.
expect "template subcommand rewrites a template" 0 \
    python3 -I "$lib" template "$template" "$work/copy.tracetemplate" "Copy for tests"
expect "rewritten template keeps every instrument" 0 \
    python3 -I "$lib" check-instruments "$work/copy.tracetemplate" "$instruments"
expect_output "rewritten template keeps the os_signpost options" "com.joeblau.blau" \
    python3 -I "$lib" signpost-subsystems "$work/copy.tracetemplate"
expect_output "rewritten template has the new description" "Copy for tests" plutil -p "$work/copy.tracetemplate"

printf 'os_signpost\nHangs\n' >"$work/short.txt"
expect "check-instruments fails when the list differs" 1 \
    python3 -I "$lib" check-instruments "$template" "$work/short.txt"

# --- tracetemplate.py check-intervals --------------------------------------------

# Writes an OSSignpostIntervals export with one row per canonical interval.
# xctrace writes each distinct value once with an id and refers back to it
# with ref=, so every second row uses refs. $1 = output, $2 = interval to
# leave out, $3 = category to use for every row ("" = documented one).
write_intervals() {
    python3 -I - "$doc" "$1" "$2" "$3" <<'PY'
import sys

doc, out, skip, forced = sys.argv[1:5]
rows = []
in_section = False
for line in open(doc, encoding="utf-8"):
    if line.startswith("## "):
        in_section = line.startswith("## Canonical intervals")
    elif in_section and line.startswith("| `"):
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        rows.append((cells[0], forced or cells[1]))
with open(out, "w", encoding="utf-8") as handle:
    handle.write('<?xml version="1.0"?>\n<trace-query-result><node>\n')
    next_id = 1
    for index, (name, category) in enumerate(rows):
        if name == skip:
            continue
        for repeat in range(2):
            if repeat == 0:
                handle.write(
                    f'<row><duration id="{next_id}" fmt="2.01 ms">2010000</duration>'
                    f'<subsystem id="{next_id + 1}" fmt="com.joeblau.blau">com.joeblau.blau</subsystem>'
                    f'<category id="{next_id + 2}" fmt="{category}">{category}</category>'
                    f'<signpost-name id="{next_id + 3}" fmt="{name}">{name}</signpost-name></row>\n'
                )
            else:
                handle.write(
                    f'<row><duration ref="{next_id}"/><subsystem ref="{next_id + 1}"/>'
                    f'<category ref="{next_id + 2}"/><signpost-name ref="{next_id + 3}"/></row>\n'
                )
        next_id += 4
    # Another subsystem's interval with a Blau name must not count.
    handle.write(
        '<row><duration fmt="1 ms">1</duration><subsystem fmt="com.example">com.example</subsystem>'
        f'<category fmt="audio">audio</category><signpost-name fmt="{skip}">{skip}</signpost-name></row>\n'
    )
    handle.write("</node></trace-query-result>\n")
PY
}

write_intervals "$work/all.xml" "" ""
expect "check-intervals passes when every interval is present" 0 \
    python3 -I "$lib" check-intervals "$work/all.xml" "$doc"

write_intervals "$work/missing.xml" "asr.chunk" ""
expect "check-intervals fails when an interval is missing" 1 \
    python3 -I "$lib" check-intervals "$work/missing.xml" "$doc"

write_intervals "$work/category.xml" "" "ui"
expect "check-intervals fails when a category is wrong" 1 \
    python3 -I "$lib" check-intervals "$work/category.xml" "$doc"

# --- tracetemplate.py check-toc --------------------------------------------------

# $1 = output, $2 = template name, $3 = os_signpost dynamic subsystems
write_toc() {
    cat >"$1" <<EOF
<?xml version="1.0"?>
<trace-toc><run number="1"><info><summary>
<duration>12.5</duration><end-reason>Target app exited</end-reason>
<template-name>$2</template-name><recording-mode>Deferred</recording-mode>
<intruments-recording-settings>
<instrument name="os_signpost"><options><option key="Dynamic Subsystems" value="$3"/></options></instrument>
</intruments-recording-settings>
</summary></info></run></trace-toc>
EOF
}

write_toc "$work/toc-ok.xml" "Blau" "com.joeblau.blau"
expect "check-toc passes for a Blau recording" 0 python3 -I "$lib" check-toc "$work/toc-ok.xml" "Blau"

write_toc "$work/toc-template.xml" "Blank" "com.joeblau.blau"
expect "check-toc fails for another template" 1 python3 -I "$lib" check-toc "$work/toc-template.xml" "Blau"

write_toc "$work/toc-subsystem.xml" "Blau" ""
expect "check-toc fails without Blau's subsystem" 1 \
    python3 -I "$lib" check-toc "$work/toc-subsystem.xml" "Blau"

# --- xctrace loads the template (no recording) ------------------------------------

if xcrun --find xctrace >/dev/null 2>&1; then
    expect_output "xctrace loads the template and its os_signpost options" '"com.joeblau.blau"' \
        xcrun xctrace record --template "$template" --show-recording-options
    expect_output "xctrace loads the template's Allocations options" '"Allocations"' \
        xcrun xctrace record --template "$template" --show-recording-options
else
    echo "skip - xctrace not found; template load not checked"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
