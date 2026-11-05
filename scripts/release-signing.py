#!/usr/bin/env python3
"""Sign a staged macOS app inside out and inspect every Mach-O architecture.

No --deep signing: each code object keeps its own entitlements. This also finds
Mach-O tools in Resources, which outer-bundle verification treats as data.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

MAGICS = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}
BUNDLE_SUFFIXES = {".app", ".xpc", ".framework", ".appex", ".bundle"}
DEBUG_ENTITLEMENT = "com.apple.security.get-task-allow"


class SigningError(RuntimeError):
    pass


def run(arguments: list[str], *, required: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(arguments, capture_output=True)
    if required and result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise SigningError(f"{arguments[0]} failed for {arguments[-1]}: {detail}")
    return result


def within(path: Path, root: Path) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise SigningError(f"Code path escapes the staged app: {path}")
    return resolved


def architectures(path: Path) -> tuple[str, ...]:
    values = run(["/usr/bin/lipo", "-archs", str(path)]).stdout.decode().split()
    if not values or len(values) != len(set(values)):
        raise SigningError(f"Invalid architecture list: {path}")
    return tuple(values)


@dataclass(frozen=True)
class CodeTarget:
    path: Path
    executable: Path
    framework: bool = False


def inventory(app: Path) -> tuple[list[Path], list[CodeTarget]]:
    binaries = []
    for path in app.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as source:
            magic = source.read(4)
        if magic in MAGICS:
            binaries.append(within(path, app))
    binaries = sorted(set(binaries))
    if not binaries:
        raise SigningError("The app contains no Mach-O executable.")
    binary_set = set(binaries)
    owners: dict[Path, CodeTarget] = {}
    bundles = [app] + [path for path in app.rglob("*")
                       if path.is_dir() and not path.is_symlink() and path.suffix in BUNDLE_SUFFIXES]
    for bundle in bundles:
        framework = bundle.suffix == ".framework"
        info_path = bundle / ("Resources/Info.plist" if framework else "Contents/Info.plist")
        if not info_path.is_file():
            if bundle == app:
                raise SigningError("App Info.plist is missing.")
            continue  # Resource-only bundles are sealed by their owning code bundle.
        info = plistlib.loads(info_path.read_bytes())
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name:
            if bundle == app:
                raise SigningError("App executable name is missing.")
            continue
        executable_path = bundle / name if framework else bundle / "Contents/MacOS" / name
        if not executable_path.exists():
            raise SigningError(f"Bundle executable is missing: {executable_path}")
        executable = within(executable_path, app)
        if executable not in binary_set:
            raise SigningError(f"Bundle executable is not Mach-O: {executable_path}")
        if executable in owners:
            raise SigningError(f"Multiple bundles claim the same executable: {executable}")
        owners[executable] = CodeTarget(bundle, executable, framework)
    targets = [owners.get(binary, CodeTarget(binary, binary)) for binary in binaries]
    # Nested app/XPC services and loose tools precede their containing frameworks;
    # every framework precedes the main app. Ties are deterministic.
    targets.sort(key=lambda target: (-len(target.path.relative_to(app).parts), str(target.path)))
    if not targets or targets[-1].path != app:
        raise SigningError("Main app was not identified as the final signing target.")
    return binaries, targets


def read_entitlements(path: Path, architecture: str, *, allow_unsigned: bool) -> dict:
    result = run(["/usr/bin/codesign", "-d", "--architecture", architecture,
                  "--entitlements", ":-", str(path)], required=False)
    if result.returncode:
        message = result.stderr.decode("utf-8", "replace")
        if allow_unsigned and "not signed at all" in message:
            return {}
        raise SigningError(f"Cannot read {architecture} entitlements for {path}: {message.strip()}")
    if not result.stdout.strip():
        return {}
    try:
        entitlements = plistlib.loads(result.stdout)
    except Exception as error:
        raise SigningError(f"Invalid entitlement plist for {path} ({architecture})") from error
    if not isinstance(entitlements, dict):
        raise SigningError(f"Entitlements are not a dictionary: {path}")
    return entitlements


def preserved_entitlements(target: CodeTarget) -> dict:
    variants = []
    for architecture in architectures(target.executable):
        values = read_entitlements(target.path, architecture, allow_unsigned=True)
        values.pop(DEBUG_ENTITLEMENT, None)
        variants.append(values)
    if any(values != variants[0] for values in variants[1:]):
        raise SigningError(f"Architecture-specific entitlements differ; review before signing: {target.path}")
    if target.framework and variants[0]:
        raise SigningError(f"Framework unexpectedly contains entitlements; review before signing: {target.path}")
    return variants[0]


def verify(app: Path, team: str) -> None:
    binaries, targets = inventory(app)
    errors = []
    slices = 0
    for binary in binaries:
        for architecture in architectures(binary):
            slices += 1
            label = f"{binary.relative_to(app)} [{architecture}]"
            display = run(["/usr/bin/codesign", "-d", "--verbose=4", "--architecture",
                           architecture, str(binary)], required=False)
            metadata = display.stderr.decode("utf-8", "replace")
            if display.returncode:
                errors.append(f"{label}: no readable code signature")
                continue
            if "Authority=Developer ID Application:" not in metadata:
                errors.append(f"{label}: not signed by Developer ID Application")
            if f"TeamIdentifier={team}\n" not in metadata:
                errors.append(f"{label}: unexpected/missing signing team")
            if not re.search(r"^Timestamp=.+$", metadata, re.MULTILINE):
                errors.append(f"{label}: no secure timestamp")
            flags = re.search(r"\bflags=(0x[0-9a-fA-F]+)", metadata)
            if not flags or not int(flags.group(1), 16) & 0x10000:
                errors.append(f"{label}: hardened runtime is missing")
            try:
                if read_entitlements(binary, architecture, allow_unsigned=False).get(DEBUG_ENTITLEMENT, False):
                    errors.append(f"{label}: debugging entitlement is enabled")
            except SigningError as error:
                errors.append(str(error))
            checked = run(["/usr/bin/codesign", "--verify", "--strict", "--architecture",
                           architecture, str(binary)], required=False)
            if checked.returncode:
                errors.append(f"{label}: invalid code signature")
    # Check resource envelopes as well as the executable slices. The final deep
    # check is verification only and catches nested bundle/seal inconsistencies.
    for target in targets:
        if target.path.is_dir():
            checked = run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
                           str(target.path)], required=False)
            if checked.returncode:
                errors.append(f"{target.path.relative_to(app)}: invalid bundle seal")
    checked = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures",
                   str(app)], required=False)
    if checked.returncode:
        errors.append("Main app recursive signature verification failed.")
    if errors:
        raise SigningError("Distribution signing preflight failed:\n" + "\n".join("- " + error for error in errors))
    print(f"Passed: {len(binaries)} Mach-O files / {slices} architecture slices; Developer ID, team, secure timestamp, hardened runtime, entitlements, and bundle seals.")


def sign(app: Path, identity: str, team: str) -> None:
    _, targets = inventory(app)
    # Read all existing per-target entitlements before modifying any nested seal.
    metadata = {target.path: preserved_entitlements(target) for target in targets}
    with tempfile.TemporaryDirectory(prefix="heynotch-release-entitlements-") as temporary:
        for index, target in enumerate(targets):
            command = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp",
                       "--options", "runtime", "--preserve-metadata=identifier"]
            entitlements = metadata[target.path]
            if entitlements:
                file = Path(temporary) / f"{index}.plist"
                file.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML))
                command += ["--entitlements", str(file), "--generate-entitlement-der"]
            command.append(str(target.path))
            run(command)
            print("Signed:", target.path.relative_to(app) if target.path != app else app.name)
    verify(app, team)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    signing = commands.add_parser("sign", help="Sign explicit code objects inside out, then verify")
    signing.add_argument("app", type=Path)
    signing.add_argument("identity")
    signing.add_argument("team")
    checking = commands.add_parser("verify", help="Verify every Mach-O architecture and nested code seal")
    checking.add_argument("app", type=Path)
    checking.add_argument("team")
    args = parser.parse_args()
    try:
        app = args.app.resolve(strict=True)
        if not app.is_dir() or app.suffix != ".app":
            raise SigningError("Expected a staged .app directory.")
        if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
            raise SigningError("Expected a 10-character Apple Developer team ID.")
        if args.command == "sign":
            sign(app, args.identity, args.team)
        else:
            verify(app, args.team)
        return 0
    except (SigningError, OSError, plistlib.InvalidFileException, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
