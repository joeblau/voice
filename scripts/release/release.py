#!/usr/bin/env python3
"""Helpers for Blau's TestFlight release pipeline (#83, docs/release.md).

    release.py version [--ref REF] [--run-number N] [--build-offset K] [--build-number N]
    release.py schema [--deployed VERSION] [--warn-only]
    release.py notes [--to REF] [--from REF] [--version V] [--build N] [--markdown FILE] [--text FILE]
    release.py export-options --output FILE [--team TEAM] [--internal-only]
    release.py verify-ipa (--ipa FILE | --app DIR) --version V --build N [--report FILE]

`version` turns the pushed ref and the workflow run number into the
marketing version and build number, and fails when a `v*` tag doesn't match
MARKETING_VERSION in project.yml. `schema` compares the persistence schema
the sources ship with the version deployed to the CloudKit Production
environment. `notes` writes release notes from the pull requests merged since
the previous `v*` tag: Markdown for the GitHub release and plain text for
TestFlight's "What to Test". `export-options` writes the ExportOptions.plist
for `xcodebuild -exportArchive`. `verify-ipa` checks an exported IPA before it
is uploaded: versions, build configuration, distribution signing and the
iCloud / push entitlements.

When GITHUB_OUTPUT is set (GitHub Actions), `version` and `schema` append
their key=value results to it as step outputs.

Exit status: 0 on success, 1 on a failed check, 2 on bad usage.
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent.parent
BUNDLE_ID = "com.joeblau.blau"
CONTAINER = "iCloud.com.joeblau.blau"
TAG_PATTERN = re.compile(r"^v(?P<version>\d+(?:\.\d+){0,2})(?:-(?P<suffix>[0-9A-Za-z][0-9A-Za-z.-]*))?$")
MARKETING_VERSION_PATTERN = re.compile(r"^\d+(?:\.\d+){0,2}$")
# TestFlight's "What to Test" field holds at most 4,000 characters.
WHAT_TO_TEST_LIMIT = 4000
# CFBundleVersion: at most three period-separated integers, here always one.
MAX_BUILD_NUMBER = 10**18 - 1


class UsageError(Exception):
    pass


class CheckFailed(Exception):
    pass


def write_github_output(values):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def print_values(values):
    for key, value in values.items():
        print(f"{key}={value}")
    write_github_output(values)


# --- version ----------------------------------------------------------------------


def project_marketing_version(project):
    """MARKETING_VERSION from project.yml's project-level settings."""
    text = Path(project).read_text(encoding="utf-8")
    match = re.search(r"^\s*MARKETING_VERSION:\s*[\"']?([^\"'\s#]+)[\"']?", text, re.MULTILINE)
    if not match:
        raise CheckFailed(f"{project}: no MARKETING_VERSION setting")
    version = match.group(1)
    if not MARKETING_VERSION_PATTERN.match(version):
        raise CheckFailed(
            f"{project}: MARKETING_VERSION {version!r} must be one to three integers separated by periods"
        )
    return version


def tag_from_ref(ref):
    """The tag name for refs/tags/<tag> or a bare v* name, else None."""
    if not ref:
        return None
    if ref.startswith("refs/tags/"):
        return ref[len("refs/tags/") :]
    if ref.startswith("refs/"):
        return None
    return ref if ref.startswith("v") else None


def build_number(arguments):
    if arguments.build_number is not None:
        number = arguments.build_number
    elif arguments.run_number is not None:
        number = arguments.build_offset + arguments.run_number
    else:
        raise UsageError("pass --run-number (GitHub's run number) or --build-number")
    if not 1 <= number <= MAX_BUILD_NUMBER:
        raise CheckFailed(f"build number {number} is out of range (1 to {MAX_BUILD_NUMBER})")
    return number


def command_version(arguments):
    marketing_version = project_marketing_version(arguments.project)
    tag = tag_from_ref(arguments.ref)
    if tag is not None:
        match = TAG_PATTERN.match(tag)
        if not match:
            raise CheckFailed(
                f"tag {tag!r} is not a release tag: use v<major>.<minor>.<patch>, optionally with a "
                "suffix such as v0.1.0-beta.2"
            )
        if match.group("version") != marketing_version:
            raise CheckFailed(
                f"tag {tag} is version {match.group('version')} but project.yml's MARKETING_VERSION is "
                f"{marketing_version}: bump MARKETING_VERSION on main first, then tag that commit"
            )
    print_values(
        {
            "marketing_version": marketing_version,
            "build_number": build_number(arguments),
            "tag": tag or "",
        }
    )


# --- schema -----------------------------------------------------------------------


def normalized_version(text):
    parts = text.strip().split(".")
    if not 1 <= len(parts) <= 3 or not all(part.isdigit() for part in parts):
        raise CheckFailed(f"{text!r} is not a schema version such as 2.0.0")
    parts += ["0"] * (3 - len(parts))
    return ".".join(str(int(part)) for part in parts)


def current_schema_version(package):
    schema_dir = Path(package) / "Sources" / "BlauPersistence" / "Schema"
    current = schema_dir / "CurrentSchema.swift"
    match = re.search(r"typealias\s+CurrentSchema\s*=\s*(\w+)", current.read_text(encoding="utf-8"))
    if not match:
        raise CheckFailed(f"{current}: no `typealias CurrentSchema = ...`")
    name = match.group(1)
    source = schema_dir / f"{name}.swift"
    if not source.exists():
        raise CheckFailed(f"{source}: missing (CurrentSchema is {name})")
    version = re.search(
        r"versionIdentifier\s*=\s*Schema\.Version\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)",
        source.read_text(encoding="utf-8"),
    )
    if not version:
        raise CheckFailed(f"{source}: no `versionIdentifier = Schema.Version(major, minor, patch)`")
    return name, ".".join(version.groups())


def command_schema(arguments):
    name, version = current_schema_version(arguments.package)
    print_values({"schema": name, "schema_version": version})
    deployed = (arguments.deployed or "").strip()
    if deployed and normalized_version(deployed) == version:
        print(f"CloudKit Production schema {deployed} matches {name} ({version}).")
        return
    if deployed:
        problem = (
            f"this build ships {name} ({version}) but the CloudKit Production schema is recorded as "
            f"{deployed}"
        )
    else:
        problem = f"this build ships {name} ({version}) and no deployed Production schema is recorded"
    advice = (
        "Run the Production schema deploy checklist in docs/release.md, then set the repository "
        f"variable BLAU_CLOUDKIT_PRODUCTION_SCHEMA to {version}."
    )
    if arguments.warn_only:
        print(f"::warning title=CloudKit schema::{problem}. {advice}")
        return
    raise CheckFailed(f"{problem}. {advice}")


# --- notes ------------------------------------------------------------------------


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True, cwd=os.getcwd())
    if check and result.returncode != 0:
        raise CheckFailed(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def previous_tag(to_ref):
    """The newest v* tag reachable from to_ref's first parent, or None."""
    if git("rev-parse", "--verify", "--quiet", f"{to_ref}^", check=False).returncode != 0:
        return None
    result = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", f"{to_ref}^", check=False)
    return result.stdout.strip() or None


def github_repository():
    repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if repository:
        return repository
    url = git("remote", "get-url", "origin", check=False).stdout.strip()
    match = re.search(r"github\.com[:/](?P<repo>[^/]+/[^/]+?)(?:\.git)?/?$", url)
    return match.group("repo") if match else None


def merged_changes(from_ref, to_ref):
    """(number or None, title, short sha) for each first-parent commit, newest first."""
    revision = f"{from_ref}..{to_ref}" if from_ref else to_ref
    log = git("log", "--first-parent", "--format=%H%x1f%s%x1f%b%x1e", revision).stdout
    changes = []
    for record in log.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, subject, body = (record.split("\x1f") + ["", ""])[:3]
        merge = re.match(r"^Merge pull request #(\d+) from \S+", subject)
        if merge:
            lines = [line.strip() for line in body.splitlines() if line.strip()]
            changes.append((int(merge.group(1)), lines[0] if lines else subject, sha[:7]))
            continue
        squash = re.match(r"^(?P<title>.*?)\s*\(#(?P<number>\d+)\)$", subject)
        if squash:
            changes.append((int(squash.group("number")), squash.group("title"), sha[:7]))
        else:
            changes.append((None, subject, sha[:7]))
    return changes


def heading(arguments):
    title = "Blau"
    if arguments.version:
        title += f" {arguments.version}"
        if arguments.build:
            title += f" ({arguments.build})"
    return title


def markdown_notes(arguments, changes, from_ref, repository):
    lines = [f"## {heading(arguments)}", ""]
    if from_ref:
        lines.append(f"Changes since {from_ref}:")
    else:
        lines.append("Changes in this first release:")
    lines.append("")
    if not changes:
        lines.append("- No merged changes.")
    for number, title, sha in changes:
        if number is not None:
            link = f"[#{number}](https://github.com/{repository}/pull/{number})" if repository else f"#{number}"
            lines.append(f"- {title} ({link})")
        else:
            lines.append(f"- {title} ({sha})")
    if from_ref and repository:
        target = arguments.to
        if target.upper() == "HEAD":
            target = git("rev-parse", "HEAD").stdout.strip()
        lines += ["", f"**Full changelog**: https://github.com/{repository}/compare/{from_ref}...{target}"]
    return "\n".join(lines) + "\n"


def text_notes(arguments, changes, from_ref, repository):
    header = [heading(arguments), ""]
    header.append(f"Changes since {from_ref}:" if from_ref else "Changes in this first release:")
    items = []
    for number, title, sha in changes:
        items.append(f"- {title} (#{number})" if number is not None else f"- {title}")
    if not items:
        items.append("- No merged changes.")
    text = "\n".join(header + items) + "\n"
    if len(text) <= WHAT_TO_TEST_LIMIT:
        return text
    # Keep whole lines and say how many were left out, within the limit.
    where = f" See https://github.com/{repository}/releases" if repository else ""
    kept = []
    for count in range(len(items), -1, -1):
        footer = f"- ...and {len(items) - count} more.{where}"
        candidate = "\n".join(header + items[:count] + [footer]) + "\n"
        if len(candidate) <= WHAT_TO_TEST_LIMIT:
            kept = candidate
            break
    return kept or text[:WHAT_TO_TEST_LIMIT]


def command_notes(arguments):
    if git("rev-parse", "--verify", "--quiet", f"{arguments.to}^{{commit}}", check=False).returncode != 0:
        raise CheckFailed(f"{arguments.to} is not a commit")
    from_ref = arguments.from_ref if arguments.from_ref else previous_tag(arguments.to)
    repository = arguments.repo or github_repository()
    changes = merged_changes(from_ref, arguments.to)
    markdown = markdown_notes(arguments, changes, from_ref, repository)
    text = text_notes(arguments, changes, from_ref, repository)
    if arguments.markdown:
        Path(arguments.markdown).parent.mkdir(parents=True, exist_ok=True)
        Path(arguments.markdown).write_text(markdown, encoding="utf-8")
    if arguments.text:
        Path(arguments.text).parent.mkdir(parents=True, exist_ok=True)
        Path(arguments.text).write_text(text, encoding="utf-8")
    if not arguments.markdown and not arguments.text:
        sys.stdout.write(markdown)
    else:
        pull_requests = sum(1 for number, _, _ in changes if number is not None)
        print(f"{len(changes)} change(s), {pull_requests} pull request(s), since {from_ref or 'the first commit'}")


# --- export-options ---------------------------------------------------------------


def command_export_options(arguments):
    options = {
        "method": "app-store-connect",
        # Export the IPA here and upload it in a separate step, so it can be
        # verified first (verify-ipa).
        "destination": "export",
        "signingStyle": "automatic",
        "uploadSymbols": True,
        "stripSwiftSymbols": True,
        # The build number is the workflow's (docs/release.md); never let
        # Xcode rewrite it.
        "manageAppVersionAndBuildNumber": False,
        # TestFlight and the App Store use the Production CloudKit environment.
        "iCloudContainerEnvironment": "Production",
        "testFlightInternalTestingOnly": bool(arguments.internal_only),
    }
    if arguments.team:
        options["teamID"] = arguments.team
    Path(arguments.output).parent.mkdir(parents=True, exist_ok=True)
    with open(arguments.output, "wb") as output:
        plistlib.dump(options, output)
    print(f"Wrote {arguments.output}")


# --- verify-ipa -------------------------------------------------------------------


class Checks:
    def __init__(self):
        self.results = []

    def check(self, passed, description, detail=""):
        self.results.append((bool(passed), description, " ".join(str(detail).split())))

    @property
    def failures(self):
        return [result for result in self.results if not result[0]]


def read_plist(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def entitlements(bundle):
    """The signed entitlements, or {} for an unsigned bundle (its signature check fails)."""
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)], capture_output=True
    )
    if result.returncode != 0:
        return {}
    start = result.stdout.find(b"<?xml")
    if start < 0:
        return {}
    return plistlib.loads(result.stdout[start:])


def signature_details(bundle):
    result = subprocess.run(["codesign", "-d", "-vv", str(bundle)], capture_output=True, text=True)
    return result.stdout + result.stderr


def signature_valid(bundle):
    result = subprocess.run(["codesign", "--verify", "--strict", str(bundle)], capture_output=True, text=True)
    return result.returncode == 0, result.stderr.strip()


def provisioning_profile(bundle):
    path = bundle / "embedded.mobileprovision"
    if not path.exists():
        return None
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    data = decoded.stdout if decoded.returncode == 0 and decoded.stdout else path.read_bytes()
    try:
        return plistlib.loads(data)
    except Exception:  # noqa: BLE001 - any parse failure means the profile is unreadable
        return {}


def check_signature(checks, bundle, name, allow_ad_hoc):
    valid, error = signature_valid(bundle)
    checks.check(valid, f"{name}: code signature is valid", error)
    details = signature_details(bundle)
    authorities = re.findall(r"^Authority=(.*)$", details, re.MULTILINE)
    distribution = bool(authorities) and re.match(r"(Apple|iPhone) Distribution", authorities[0]) is not None
    ad_hoc = "Signature=adhoc" in details
    checks.check(
        distribution or (allow_ad_hoc and ad_hoc),
        f"{name}: signed with a distribution certificate",
        authorities[0] if authorities else ("ad hoc" if ad_hoc else "unsigned"),
    )
    profile = provisioning_profile(bundle)
    checks.check(profile is not None, f"{name}: embeds a provisioning profile")
    if profile is not None:
        checks.check(
            "ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices", False),
            f"{name}: the provisioning profile is an App Store profile (no device list)",
        )
    values = entitlements(bundle)
    checks.check(
        not values.get("get-task-allow", False),
        f"{name}: get-task-allow is off (not a development signature)",
        str(values.get("get-task-allow")),
    )
    return values


def check_app(app, arguments, checks):
    info = read_plist(app / "Info.plist")
    checks.check(
        info.get("CFBundleIdentifier") == arguments.bundle_id,
        f"bundle identifier is {arguments.bundle_id}",
        str(info.get("CFBundleIdentifier")),
    )
    checks.check(
        info.get("CFBundleShortVersionString") == arguments.version,
        f"CFBundleShortVersionString is {arguments.version}",
        str(info.get("CFBundleShortVersionString")),
    )
    checks.check(
        str(info.get("CFBundleVersion")) == str(arguments.build),
        f"CFBundleVersion is {arguments.build}",
        str(info.get("CFBundleVersion")),
    )
    checks.check(
        info.get("BlauEnvironment") == "release",
        "built with the Release configuration (BlauEnvironment = release)",
        str(info.get("BlauEnvironment")),
    )
    checks.check(
        info.get("BlauCloudKitEnabled") == "YES",
        "CloudKit sync is on (BlauCloudKitEnabled = YES: the archive was signed)",
        str(info.get("BlauCloudKitEnabled")),
    )
    checks.check(
        not info.get("BlauXAIDevAPIKey"),
        "no developer xAI key in Info.plist (BlauXAIDevAPIKey is empty)",
    )
    checks.check(
        info.get("ITSAppUsesNonExemptEncryption") is False,
        "export compliance is declared (ITSAppUsesNonExemptEncryption = NO)",
        str(info.get("ITSAppUsesNonExemptEncryption")),
    )

    values = check_signature(checks, app, app.name, arguments.allow_ad_hoc_signature)
    identifier = values.get("application-identifier", "")
    checks.check(
        identifier.endswith(f".{arguments.bundle_id}"),
        f"application-identifier is <team>.{arguments.bundle_id}",
        identifier,
    )
    checks.check(
        values.get("aps-environment") == "production",
        "aps-environment is production (CloudKit change notifications)",
        str(values.get("aps-environment")),
    )
    checks.check(
        arguments.container in values.get("com.apple.developer.icloud-container-identifiers", []),
        f"iCloud container {arguments.container} is entitled",
    )
    checks.check(
        "CloudKit" in values.get("com.apple.developer.icloud-services", []),
        "the CloudKit service is entitled",
    )
    checks.check(
        arguments.container in values.get("com.apple.developer.ubiquity-container-identifiers", []),
        f"iCloud Drive container {arguments.container} is entitled (Markdown export)",
    )
    environment = values.get("com.apple.developer.icloud-container-environment", "Production")
    checks.check(
        environment == "Production",
        "iCloud container environment is Production",
        str(environment),
    )

    extensions = sorted((app / "PlugIns").glob("*.appex")) + sorted((app / "Extensions").glob("*.appex"))
    checks.check(bool(extensions), "embeds the app extensions (BlauWidgets)")
    for extension in extensions:
        extension_info = read_plist(extension / "Info.plist")
        name = extension.name
        checks.check(
            str(extension_info.get("CFBundleIdentifier", "")).startswith(f"{arguments.bundle_id}."),
            f"{name}: bundle identifier is under {arguments.bundle_id}",
            str(extension_info.get("CFBundleIdentifier")),
        )
        checks.check(
            extension_info.get("CFBundleShortVersionString") == arguments.version
            and str(extension_info.get("CFBundleVersion")) == str(arguments.build),
            f"{name}: versions match the app ({arguments.version}, {arguments.build})",
            f"{extension_info.get('CFBundleShortVersionString')} ({extension_info.get('CFBundleVersion')})",
        )
        check_signature(checks, extension, name, arguments.allow_ad_hoc_signature)


def report_markdown(arguments, checks, source):
    lines = [f"## IPA verification: {Path(source).name}", "", "| Result | Check | Found |", "| --- | --- | --- |"]
    for passed, description, detail in checks.results:
        lines.append(f"| {'ok' if passed else '**FAIL**'} | {description} | {detail.replace('|', '/')} |")
    return "\n".join(lines) + "\n"


def command_verify_ipa(arguments):
    checks = Checks()
    with tempfile.TemporaryDirectory(prefix="blau-verify-ipa.") as scratch:
        if arguments.ipa:
            source = arguments.ipa
            try:
                with zipfile.ZipFile(arguments.ipa) as archive:
                    archive.extractall(scratch)
            except (OSError, zipfile.BadZipFile) as error:
                raise CheckFailed(f"{arguments.ipa}: not a readable IPA ({error})") from error
            apps = sorted((Path(scratch) / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise CheckFailed(f"{arguments.ipa}: expected one app in Payload/, found {len(apps)}")
            # zipfile drops the executable bit, which codesign doesn't need.
            app = apps[0]
        else:
            source = arguments.app
            app = Path(arguments.app)
            if not (app / "Info.plist").exists():
                raise CheckFailed(f"{arguments.app}: not an app bundle")
        check_app(app, arguments, checks)

    for passed, description, detail in checks.results:
        suffix = f" ({detail})" if detail and not passed else ""
        print(f"{'ok  ' if passed else 'FAIL'} - {description}{suffix}")
    if arguments.report:
        Path(arguments.report).parent.mkdir(parents=True, exist_ok=True)
        Path(arguments.report).write_text(report_markdown(arguments, checks, source), encoding="utf-8")
    if checks.failures:
        raise CheckFailed(f"{len(checks.failures)} check(s) failed; the IPA is not fit for TestFlight")
    print(f"{len(checks.results)} checks passed.")


# --- main -------------------------------------------------------------------------


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    version = commands.add_parser("version", help="marketing version and build number for this run")
    version.add_argument("--ref", default="", help="the pushed ref, e.g. refs/tags/v0.1.0 ($GITHUB_REF)")
    version.add_argument("--project", default=str(REPOSITORY / "project.yml"))
    version.add_argument("--run-number", type=int, help="$GITHUB_RUN_NUMBER")
    version.add_argument("--build-offset", type=int, default=0, help="added to the run number")
    version.add_argument("--build-number", type=int, help="use this build number instead")

    schema = commands.add_parser("schema", help="check the CloudKit Production schema is deployed")
    schema.add_argument("--package", default=str(REPOSITORY / "Packages" / "BlauKit"))
    schema.add_argument("--deployed", default="", help="schema version deployed to Production")
    schema.add_argument("--warn-only", action="store_true", help="warn instead of failing (dry runs)")

    notes = commands.add_parser("notes", help="release notes from the pull requests since the last tag")
    notes.add_argument("--to", default="HEAD")
    notes.add_argument("--from", dest="from_ref", help="start after this ref (default: the previous v* tag)")
    notes.add_argument("--repo", help="owner/name for links (default: $GITHUB_REPOSITORY or origin)")
    notes.add_argument("--version")
    notes.add_argument("--build")
    notes.add_argument("--markdown", help="write the GitHub release notes here")
    notes.add_argument("--text", help="write TestFlight's What to Test text here")

    export = commands.add_parser("export-options", help="write ExportOptions.plist for App Store Connect")
    export.add_argument("--output", required=True)
    export.add_argument("--team")
    export.add_argument("--internal-only", action="store_true", help="testFlightInternalTestingOnly")

    verify = commands.add_parser("verify-ipa", help="check an exported IPA before uploading it")
    source = verify.add_mutually_exclusive_group(required=True)
    source.add_argument("--ipa")
    source.add_argument("--app")
    verify.add_argument("--version", required=True)
    verify.add_argument("--build", required=True)
    verify.add_argument("--bundle-id", default=BUNDLE_ID)
    verify.add_argument("--container", default=CONTAINER)
    verify.add_argument("--report", help="also write the results as a Markdown table")
    verify.add_argument(
        "--allow-ad-hoc-signature", action="store_true", help="accept ad hoc signatures (the script's tests only)"
    )

    arguments = parser.parse_args(argv)
    handlers = {
        "version": command_version,
        "schema": command_schema,
        "notes": command_notes,
        "export-options": command_export_options,
        "verify-ipa": command_verify_ipa,
    }
    try:
        handlers[arguments.command](arguments)
    except UsageError as error:
        print(f"release.py: {error}", file=sys.stderr)
        return 2
    except CheckFailed as error:
        print(f"release.py: {error}", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error title=Release::{error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
