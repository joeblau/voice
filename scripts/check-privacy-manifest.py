#!/usr/bin/env python3
"""Validate Blau's privacy manifests (#79, docs/privacy.md).

    check-privacy-manifest.py                 # what `make check-privacy` runs
    check-privacy-manifest.py manifest FILE...
    check-privacy-manifest.py sources --manifest FILE PATH...
    check-privacy-manifest.py bundle PATH     # a built .app or an .xcarchive

`manifest` checks each file is a property list with the four top-level keys
and only Apple's documented data types, purposes, API categories and reason
codes. `sources` scans Swift, Objective-C and C sources for the
required-reason APIs and fails when a category they use isn't declared in
the manifest (a declared category nothing uses is only a warning: the call
may come from a binary dependency). `bundle` checks that the app and every
app extension in a build or archive carry a valid PrivacyInfo.xcprivacy and
lists the manifests resource bundles bring (GRDB's, for example).

With no arguments it validates both manifests in the repository and scans
the sources each covers: the app's (Blau/, BlauKit and the FluidAudio
checkout when it is present, all linked into the app binary) and the
widget extension's.

Exit status: 0 when everything passes, 1 on a finding, 2 on bad usage.
"""

import argparse
import os
import plistlib
import re
import sys
from pathlib import Path

# Apple's lists ("Describing data use in privacy manifests" and "Describing
# use of required reason API"), October 2026.
DATA_TYPES = {
    "NSPrivacyCollectedDataType" + name
    for name in (
        "Name EmailAddress PhoneNumber PhysicalAddress OtherUserContactInfo Health Fitness PaymentInfo "
        "CreditInfo OtherFinancialInfo PreciseLocation CoarseLocation SensitiveInfo Contacts "
        "EmailsOrTextMessages PhotosorVideos AudioData GameplayContent CustomerSupport OtherUserContent "
        "BrowsingHistory SearchHistory UserID DeviceID PurchaseHistory ProductInteraction AdvertisingData "
        "OtherUsageData CrashData PerformanceData OtherDiagnosticData EnvironmentScanning Hands Head "
        "OtherDataTypes"
    ).split()
}
PURPOSES = {
    "NSPrivacyCollectedDataTypePurpose" + name
    for name in "ThirdPartyAdvertising DeveloperAdvertising Analytics ProductPersonalization AppFunctionality Other".split()
}
REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# The symbols that put a source file in each category. Apple's lists, plus
# the clocks that read the same counters (CLOCK_UPTIME_RAW is
# mach_absolute_time; AVAudioTime host time is mach time) and
# FileManager.attributesOfItem, whose result carries the file's dates.
API_PATTERNS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": [r"\bUserDefaults\b", r"\bNSUserDefaults\b", r"@AppStorage\b"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
        r"\bcreationDate\b",
        r"\bmodificationDate\b",
        r"\bfileModificationDate\b",
        r"\bfileCreationDate\b",
        r"\bcontentModificationDate(Key)?\b",
        r"\bcreationDateKey\b",
        r"\bNSFileCreationDate\b",
        r"\bNSFileModificationDate\b",
        r"\bNSURLContentModificationDateKey\b",
        r"\bNSURLCreationDateKey\b",
        r"\bgetattrlist(bulk|at)?\s*\(",
        r"\bfgetattrlist\s*\(",
        r"\b(f|l)?stat\s*\(",
        r"\bfstatat\s*\(",
        r"\battributesOfItem(AtPath)?\b",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": [
        r"\bsystemUptime\b",
        r"\bmach_absolute_time\s*\(",
        r"\bCLOCK_UPTIME_RAW\b",
        r"\bhostTime\s*\(\s*forSeconds",
    ],
    "NSPrivacyAccessedAPICategoryDiskSpace": [
        r"\bvolumeAvailableCapacity\w*",
        r"\bvolumeTotalCapacity\w*",
        r"\bNSURLVolumeAvailableCapacity\w*",
        r"\bsystemFreeSize\b",
        r"\bsystemSize\b",
        r"\bNSFileSystemFreeSize\b",
        r"\bNSFileSystemSize\b",
        r"\b(f)?statv?fs\s*\(",
    ],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": [r"\bactiveInputModes\b"],
}
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".c", ".cpp", ".h"}
SKIPPED_DIRECTORIES = {".build", ".git", "DerivedData", "Tests", "__pycache__"}

TOP_LEVEL_KEYS = {
    "NSPrivacyTracking": bool,
    "NSPrivacyTrackingDomains": list,
    "NSPrivacyCollectedDataTypes": list,
    "NSPrivacyAccessedAPITypes": list,
}


class Report:
    def __init__(self):
        self.errors = 0

    def error(self, message):
        self.errors += 1
        print(f"error: {message}", file=sys.stderr)

    @staticmethod
    def warning(message):
        print(f"warning: {message}", file=sys.stderr)

    @staticmethod
    def note(message):
        print(message)


def load_manifest(path, report):
    try:
        with open(path, "rb") as file:
            manifest = plistlib.load(file)
    except FileNotFoundError:
        report.error(f"{path}: no such file")
        return None
    except Exception as error:  # plistlib raises several types for bad input.
        report.error(f"{path}: not a property list ({error})")
        return None
    if not isinstance(manifest, dict):
        report.error(f"{path}: the top level must be a dictionary")
        return None
    return manifest


def validate_manifest(path, report):
    """Checks one manifest. Returns its declared API categories, or None."""
    manifest = load_manifest(path, report)
    if manifest is None:
        return None
    before = report.errors
    for key, kind in TOP_LEVEL_KEYS.items():
        if key not in manifest:
            report.error(f"{path}: missing {key}")
        elif not isinstance(manifest[key], kind):
            report.error(f"{path}: {key} must be a {kind.__name__}")
    for key in manifest:
        if key not in TOP_LEVEL_KEYS:
            report.error(f"{path}: unknown key {key}")

    tracking = manifest.get("NSPrivacyTracking") is True
    domains = manifest.get("NSPrivacyTrackingDomains") or []
    if not all(isinstance(domain, str) and domain for domain in domains):
        report.error(f"{path}: NSPrivacyTrackingDomains must list host names")
    if domains and not tracking:
        report.error(f"{path}: NSPrivacyTrackingDomains is only allowed when NSPrivacyTracking is true")

    seen_types = set()
    for index, entry in enumerate(manifest.get("NSPrivacyCollectedDataTypes") or []):
        where = f"{path}: NSPrivacyCollectedDataTypes[{index}]"
        if not isinstance(entry, dict):
            report.error(f"{where} must be a dictionary")
            continue
        data_type = entry.get("NSPrivacyCollectedDataType")
        if data_type not in DATA_TYPES:
            report.error(f"{where}: unknown data type {data_type!r}")
        elif data_type in seen_types:
            report.error(f"{where}: {data_type} is listed twice")
        seen_types.add(data_type)
        for flag in ("NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking"):
            if not isinstance(entry.get(flag), bool):
                report.error(f"{where}: {flag} must be true or false")
        if entry.get("NSPrivacyCollectedDataTypeTracking") is True and not tracking:
            report.error(f"{where}: used for tracking, but NSPrivacyTracking is false")
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or not purposes:
            report.error(f"{where}: NSPrivacyCollectedDataTypePurposes must list at least one purpose")
        else:
            for purpose in purposes:
                if purpose not in PURPOSES:
                    report.error(f"{where}: unknown purpose {purpose!r}")
        for key in entry:
            if key not in {
                "NSPrivacyCollectedDataType",
                "NSPrivacyCollectedDataTypeLinked",
                "NSPrivacyCollectedDataTypeTracking",
                "NSPrivacyCollectedDataTypePurposes",
            }:
                report.error(f"{where}: unknown key {key}")

    categories = set()
    for index, entry in enumerate(manifest.get("NSPrivacyAccessedAPITypes") or []):
        where = f"{path}: NSPrivacyAccessedAPITypes[{index}]"
        if not isinstance(entry, dict):
            report.error(f"{where} must be a dictionary")
            continue
        category = entry.get("NSPrivacyAccessedAPIType")
        if category not in REASONS:
            report.error(f"{where}: unknown API category {category!r}")
            continue
        if category in categories:
            report.error(f"{where}: {category} is listed twice")
        categories.add(category)
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(reasons, list) or not reasons:
            report.error(f"{where}: NSPrivacyAccessedAPITypeReasons must list at least one reason")
            continue
        for reason in reasons:
            if reason not in REASONS[category]:
                allowed = ", ".join(sorted(REASONS[category]))
                report.error(f"{where}: {reason!r} is not a reason for {category} (one of {allowed})")
        for key in entry:
            if key not in {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}:
                report.error(f"{where}: unknown key {key}")
    if report.errors == before:
        report.note(f"ok: {path}")
    return categories


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def source_files(paths):
    for root in paths:
        root = Path(root)
        if root.is_file():
            if root.suffix in SOURCE_SUFFIXES:
                yield root
            continue
        if not root.is_dir():
            continue
        for directory, subdirectories, files in os.walk(root):
            subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
            for name in sorted(files):
                if Path(name).suffix in SOURCE_SUFFIXES:
                    yield Path(directory) / name


def used_categories(paths):
    """{category: [(file, line number, matched text)]} for the given sources."""
    compiled = {category: [re.compile(p) for p in patterns] for category, patterns in API_PATTERNS.items()}
    uses = {}
    for path in source_files(paths):
        try:
            text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            for category, patterns in compiled.items():
                for pattern in patterns:
                    match = pattern.search(line)
                    if match:
                        uses.setdefault(category, []).append((path, number, match.group(0)))
                        break
    return uses


def check_sources(manifest_path, paths, report):
    declared = validate_manifest(manifest_path, report)
    if declared is None:
        return
    missing = [p for p in paths if not Path(p).exists()]
    for path in missing:
        report.warning(f"{path}: not found, not scanned")
    uses = used_categories([p for p in paths if Path(p).exists()])
    for category in sorted(uses):
        sites = uses[category]
        first = ", ".join(f"{path}:{line} ({symbol})" for path, line, symbol in sites[:3])
        more = f" and {len(sites) - 3} more" if len(sites) > 3 else ""
        if category in declared:
            report.note(f"ok: {category} declared; used at {first}{more}")
        else:
            report.error(f"{manifest_path}: {category} is used but not declared: {first}{more}")
    for category in sorted(declared - set(uses)):
        report.warning(
            f"{manifest_path}: {category} is declared but no scanned source uses it "
            "(fine if a binary dependency does)"
        )


def check_bundle(path, report):
    root = Path(path)
    if not root.exists():
        report.error(f"{path}: no such file or directory")
        return
    if root.suffix == ".xcarchive":
        applications = sorted((root / "Products" / "Applications").glob("*.app"))
        if not applications:
            report.error(f"{path}: the archive holds no app in Products/Applications")
            return
    else:
        applications = [root]
    for application in applications:
        bundles = [application] + sorted((application / "PlugIns").glob("*.appex"))
        for bundle in bundles:
            manifest = bundle / "PrivacyInfo.xcprivacy"
            if manifest.exists():
                validate_manifest(manifest, report)
            else:
                report.error(f"{bundle}: no PrivacyInfo.xcprivacy at the bundle's root")
            for resource in sorted(bundle.glob("*.bundle")):
                inner = resource / "PrivacyInfo.xcprivacy"
                if inner.exists():
                    validate_manifest(inner, report)
                else:
                    report.note(f"note: {resource.name} has no privacy manifest")


def check_repository(report):
    repository = Path(__file__).resolve().parent.parent
    os.chdir(repository)
    app_sources = ["Blau", "Packages/BlauKit/Sources"]
    fluid_audio = Path("Packages/BlauKit/.build/checkouts/FluidAudio/Sources")
    if fluid_audio.is_dir():
        app_sources.append(str(fluid_audio))
    else:
        report.warning("FluidAudio isn't checked out (run `swift package resolve` in Packages/BlauKit); not scanned")
    check_sources("Blau/Resources/PrivacyInfo.xcprivacy", app_sources, report)
    check_sources(
        "BlauWidgets/PrivacyInfo.xcprivacy",
        ["BlauWidgets", "Blau/LiveActivity/RecordingActivityAttributes.swift"],
        report,
    )


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    subcommands = parser.add_subparsers(dest="command")
    manifest_command = subcommands.add_parser("manifest", help="validate manifest files")
    manifest_command.add_argument("files", nargs="+")
    sources_command = subcommands.add_parser("sources", help="check sources against a manifest")
    sources_command.add_argument("--manifest", required=True)
    sources_command.add_argument("paths", nargs="+")
    bundle_command = subcommands.add_parser("bundle", help="check a built .app or an .xcarchive")
    bundle_command.add_argument("path")
    arguments = parser.parse_args(argv)

    report = Report()
    if arguments.command == "manifest":
        for file in arguments.files:
            validate_manifest(file, report)
    elif arguments.command == "sources":
        check_sources(arguments.manifest, arguments.paths, report)
    elif arguments.command == "bundle":
        check_bundle(arguments.path, report)
    else:
        check_repository(report)
    if report.errors:
        print(f"{report.errors} privacy manifest problem(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
