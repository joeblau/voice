"""Helpers for Blau's Instruments template and os_signpost traces.

Used by scripts/make-instruments-template.sh, scripts/verify-instruments-template.sh,
scripts/verify-signposts.sh and scripts/tests/test-instruments-template.sh.
Standard library only; run with `python3 -I`.

Subcommands:

  template <form.template> <out.tracetemplate> <description>
      Turns the `form.template` inside a .trace bundle into a reusable
      .tracetemplate: drops the recorded run, symbol stores and per-run
      instrument lists, sets the description and keeps only the archived
      objects the template still references.

  instruments <file.tracetemplate>
      Prints the instruments a template (or a trace's form.template)
      configures, one name per line, in track order.

  signpost-subsystems <file.tracetemplate>
      Prints the subsystems the template's os_signpost instrument enables
      dynamic tracing for, one per line.

  check-intervals <intervals.xml> <performance.md>
      Checks an exported OSSignpostIntervals table: every interval in the
      "Canonical intervals" table of docs/performance.md must appear under
      the com.joeblau.blau subsystem with its documented category.

  check-instruments <file.tracetemplate> <instruments.txt>
      Checks a template, or the form.template of a trace recorded with it,
      configures exactly the instruments in instruments.txt, in order.

  check-toc <toc.xml> <template name>
      Checks a trace's table of contents (`xctrace export --toc`): the run
      was recorded with the named template, and os_signpost had dynamic
      tracing on for com.joeblau.blau.

A .tracetemplate is an NSKeyedArchiver binary plist. Its `$top` holds the
instrument count in "$0", then for each instrument its type identifier
followed by its archived configuration. `stubInfoByUUID` maps most
identifiers to display names, and `templateRunCommand` holds the recording
mode and limits. A recorded trace's `form.template` has the same layout
plus the run data and symbol stores, which `template` removes.
"""

import collections
import json
import plistlib
import sys
import xml.etree.ElementTree as ET

SUBSYSTEM = "com.joeblau.blau"
OS_SIGNPOST_ID = "com.apple.dt.os-log-signpost-instrument"

# $top keys that belong to a recording, not to a template.
RUN_KEYS = (
    "com.apple.xray.run.data",
    "com.apple.dt.instruments.instruments-by-run-number",
    "com.apple.xray.symbolstore.kern.signatures",
    "com.apple.xray.symbolstore.sharedcache.signatures",
    "com.apple.xray.symbolstoremanager.symbolstores",
)
DESCRIPTION_KEY = "com.apple.xray.owner.template.description"


# MARK: - Keyed archive access


def load(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def resolve(archive, value):
    """Follows a UID to the archived object it points at."""
    if isinstance(value, plistlib.UID):
        return archive["$objects"][value.data]
    return value


def class_name(archive, obj):
    if isinstance(obj, dict) and "$class" in obj:
        return resolve(archive, obj["$class"])["$classname"]
    return None


def string_value(archive, value):
    obj = resolve(archive, value)
    if isinstance(obj, dict) and "NS.string" in obj:
        return obj["NS.string"]
    return obj


def dictionary(archive, value):
    """Decodes an archived NSDictionary into {key: archived value}."""
    obj = resolve(archive, value)
    keys = [string_value(archive, key) for key in obj.get("NS.keys", [])]
    return dict(zip(keys, obj.get("NS.objects", [])))


def array(archive, value):
    obj = resolve(archive, value)
    return list(obj.get("NS.objects", []))


def instrument_entries(archive):
    """Returns [(type identifier, [configuration UIDs])], one per instrument.

    After the count in "$0", each instrument is its type identifier (a
    plain string) followed by one or more archived objects; the first is
    its configuration dictionary. Allocations, for example, writes two.
    """
    top = archive["$top"]
    count = resolve(archive, top["$0"])
    entries = []
    index = 1
    while f"${index}" in top:
        value = top[f"${index}"]
        if isinstance(resolve(archive, value), str):
            entries.append((resolve(archive, value), []))
        elif entries:
            entries[-1][1].append(value)
        index += 1
    if len(entries) != count:
        sys.exit(f"template lists {count} instruments but encodes {len(entries)}")
    return entries


# Instruments that predate the stub table, by type identifier.
LEGACY_NAMES = {"com.apple.xray.instrument-type.oa": "Allocations"}


def instrument_names(archive):
    stubs = dictionary(archive, archive["$top"]["stubInfoByUUID"])
    names = []
    for identifier, _ in instrument_entries(archive):
        stub = dictionary(archive, stubs[identifier]) if identifier in stubs else {}
        if "name" in stub:
            names.append(string_value(archive, stub["name"]))
        else:
            names.append(LEGACY_NAMES.get(identifier, identifier))
    return names


def recording_options(archive, instrument_id):
    """The recording options an instrument was configured with.

    They are the JSON `xctrace record --show-recording-options` prints,
    stored as "optionsEncoded" in the "state" of the configuration
    dictionary's "recordingControlState" (an XRInstrumentControlState).
    """
    for identifier, objects in instrument_entries(archive):
        if identifier != instrument_id or not objects:
            continue
        control = dictionary(archive, objects[0]).get("recordingControlState")
        if control is None:
            return {}
        state = dictionary(archive, resolve(archive, control)["state"])
        encoded = resolve(archive, state["optionsEncoded"]) if "optionsEncoded" in state else None
        return json.loads(encoded) if isinstance(encoded, bytes) else {}
    return {}


def signpost_subsystems(archive):
    """Subsystems os_signpost turns dynamic tracing on for."""
    return recording_options(archive, OS_SIGNPOST_ID).get("dynamicTracingEnabledSubsystems", [])


# MARK: - template


def uids_in(value):
    if isinstance(value, plistlib.UID):
        yield value.data
    elif isinstance(value, dict):
        for item in value.values():
            yield from uids_in(item)
    elif isinstance(value, list):
        for item in value:
            yield from uids_in(item)


def remap(value, mapping):
    if isinstance(value, plistlib.UID):
        return plistlib.UID(mapping[value.data])
    if isinstance(value, dict):
        return {key: remap(item, mapping) for key, item in value.items()}
    if isinstance(value, list):
        return [remap(item, mapping) for item in value]
    return value


def make_template(form_path, out_path, description):
    archive = load(form_path)
    objects = archive["$objects"]
    top = archive["$top"]

    for key in RUN_KEYS:
        top.pop(key, None)

    # The description is an NSMutableString; reuse its class entry.
    description_obj = resolve(archive, top[DESCRIPTION_KEY])
    if class_name(archive, description_obj) not in ("NSMutableString", "NSString"):
        sys.exit(f"unexpected description object: {description_obj!r}")
    objects.append({"$class": description_obj["$class"], "NS.string": description})
    top[DESCRIPTION_KEY] = plistlib.UID(len(objects) - 1)

    # Keep $null (index 0) and everything reachable from $top, in the
    # original order, then renumber the references.
    reachable = {0}
    pending = list(uids_in(top))
    while pending:
        index = pending.pop()
        if index in reachable:
            continue
        reachable.add(index)
        pending.extend(uids_in(objects[index]))
    kept = sorted(reachable)
    mapping = {old: new for new, old in enumerate(kept)}
    archive["$objects"] = [remap(objects[old], mapping) for old in kept]
    archive["$top"] = remap(top, mapping)

    with open(out_path, "wb") as handle:
        plistlib.dump(archive, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)
    return len(objects), len(kept)


# MARK: - checks


def canonical_intervals(doc_path):
    """The "Canonical intervals" table in docs/performance.md: name -> category."""
    expected = {}
    in_section = False
    with open(doc_path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("## "):
                in_section = line.startswith("## Canonical intervals")
                continue
            if in_section and line.startswith("| `"):
                cells = [cell.strip().strip("`") for cell in line.strip().strip("|").split("|")]
                expected[cells[0]] = cells[1]
    if not expected:
        sys.exit(f"No canonical intervals found in {doc_path}")
    return expected


def check_intervals(xml_path, doc_path):
    expected = canonical_intervals(doc_path)

    # xctrace writes each distinct value once with an id and refers back to
    # it with ref=, so resolve refs while walking the rows in document order.
    values = {}

    def text_of(element):
        if element is None:
            return None
        ref = element.get("ref")
        if ref is not None:
            return values.get(ref)
        value = element.get("fmt", element.text)
        if element.get("id") is not None:
            values[element.get("id")] = value
        return value

    found = collections.defaultdict(list)
    for _, element in ET.iterparse(xml_path, events=("end",)):
        if element.tag != "row":
            # Register ids on leaf values as they stream past.
            if element.get("id") is not None and element.get("id") not in values:
                values[element.get("id")] = element.get("fmt", element.text)
            continue
        name = text_of(element.find("signpost-name"))
        category = text_of(element.find("category"))
        subsystem = text_of(element.find("subsystem"))
        duration = element.find("duration")
        if subsystem == SUBSYSTEM:
            found[name].append((category, text_of(duration)))

    print(f"\n{'interval':<22} {'category':<10} {'count':>5}  example duration")
    failures = []
    for name, category in expected.items():
        rows = found.get(name, [])
        categories = {c for c, _ in rows}
        example = rows[0][1] if rows else "-"
        print(f"{name:<22} {category:<10} {len(rows):>5}  {example}")
        if not rows:
            failures.append(f"{name}: no intervals in the trace")
        elif categories != {category}:
            failures.append(f"{name}: categories {sorted(categories)}, expected {category}")

    if failures:
        print("\nFAILED:\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1
    print(f"\nOK: all {len(expected)} canonical intervals recorded under {SUBSYSTEM}.")
    return 0


def listed_instruments(path):
    """The instrument names in Tools/Instruments/instruments.txt, in order."""
    with open(path, encoding="utf-8") as handle:
        lines = [line.strip() for line in handle]
    return [line for line in lines if line and not line.startswith("#")]


def check_instruments(template_path, instruments_path):
    """Checks a template (or a trace's form.template) has exactly the listed instruments."""
    expected = listed_instruments(instruments_path)
    actual = instrument_names(load(template_path))
    if actual == expected:
        print(f"OK: {len(actual)} instruments: {', '.join(actual)}")
        return 0
    print(f"FAILED: instruments differ from {instruments_path}", file=sys.stderr)
    print(f"  expected: {expected}\n  actual:   {actual}", file=sys.stderr)
    missing = [name for name in expected if name not in actual]
    extra = [name for name in actual if name not in expected]
    if missing:
        print(f"  missing:  {missing}", file=sys.stderr)
    if extra:
        print(f"  extra:    {extra}", file=sys.stderr)
    return 1


def check_toc(toc_path, template_name):
    """Checks a trace's table of contents (`xctrace export --toc`).

    The run must have been recorded with `template_name`, and its
    os_signpost instrument must have had Blau's subsystem enabled.
    """
    run = ET.parse(toc_path).getroot().find("run")
    summary = run.find("info/summary") if run is not None else None
    if summary is None:
        print("FAILED: the trace has no recorded run", file=sys.stderr)
        return 1

    recorded_template = summary.findtext("template-name")
    subsystems = None
    for instrument in summary.iter("instrument"):
        if instrument.get("name") != "os_signpost":
            continue
        for option in instrument.iter("option"):
            if option.get("key") == "Dynamic Subsystems":
                subsystems = option.get("value")

    print(f"template:    {recorded_template}")
    print(f"mode:        {summary.findtext('recording-mode')}")
    print(f"duration:    {summary.findtext('duration')} s")
    print(f"end reason:  {summary.findtext('end-reason')}")
    print(f"os_signpost dynamic subsystems: {subsystems}")

    failures = []
    if recorded_template != template_name:
        failures.append(f"recorded with template {recorded_template!r}, expected {template_name!r}")
    if subsystems is None or SUBSYSTEM not in subsystems.replace(",", " ").split():
        failures.append(f"os_signpost dynamic subsystems {subsystems!r}, expected {SUBSYSTEM}")
    if failures:
        print("FAILED:\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1
    return 0


# MARK: - main


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    command, args = argv[1], argv[2:]
    if command == "template" and len(args) == 3:
        before, after = make_template(*args)
        print(f"Wrote {args[1]} ({after} archived objects, {before - after} run objects dropped)")
        return 0
    if command == "instruments" and len(args) == 1:
        print("\n".join(instrument_names(load(args[0]))))
        return 0
    if command == "signpost-subsystems" and len(args) == 1:
        print("\n".join(signpost_subsystems(load(args[0]))))
        return 0
    if command == "check-intervals" and len(args) == 2:
        return check_intervals(*args)
    if command == "check-instruments" and len(args) == 2:
        return check_instruments(*args)
    if command == "check-toc" and len(args) == 2:
        return check_toc(*args)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
