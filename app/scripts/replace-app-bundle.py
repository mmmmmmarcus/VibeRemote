#!/usr/bin/env python3
"""Validate and atomically replace vvhisper. Never requests or changes permissions."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


BUNDLE_ID = "com.viberemote.app"
TEAM_ID = "Q9MD524YL5"
EXECUTABLE = "vvhisper"
PREFIX = ".vvhisper-install-"
# Darwin SDK usr/include/sys/stdio.h (not the Linux renameat2 flags).
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
PERSONAL_REQUIREMENT = (
    f'identifier "{BUNDLE_ID}" and anchor apple generic and '
    'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
    'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
    f'certificate leaf[subject.OU] = "{TEAM_ID}"'
)


class InstallError(RuntimeError):
    pass


def absolute_path(path):
    path = Path(path).expanduser().absolute()
    return path.parent.resolve() / path.name


def snapshot(path):
    if path.is_symlink():
        raise InstallError(f"Refusing a symlink app path: {path}")
    try:
        stat = path.stat()
    except FileNotFoundError:
        return None
    if not path.is_dir():
        raise InstallError(f"App path is not a directory: {path}")
    return [stat.st_dev, stat.st_ino]


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise InstallError(f"{arguments[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout + "\n" + result.stderr


def validate_bundle(path):
    if snapshot(path) is None:
        raise InstallError(f"Missing app: {path}")
    with (path / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != EXECUTABLE:
        raise InstallError(f"Unexpected app identifier or executable: {path}")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R=" + PERSONAL_REQUIREMENT, str(path))
    details = run("/usr/bin/codesign", "--display", "-r-", str(path))
    for line in details.splitlines():
        if line.startswith("designated => "):
            requirement = line.removeprefix("designated => ").strip()
            if requirement:
                return requirement
    raise InstallError(f"No designated requirement found: {path}")


def check_compatibility(first, first_requirement, second, second_requirement):
    # Evaluate requirements, rather than comparing their textual formatting.
    run("/usr/bin/codesign", "--verify", "--strict", "-R=" + first_requirement, str(second))
    run("/usr/bin/codesign", "--verify", "--strict", "-R=" + second_requirement, str(first))


def rename(source, destination, flag):
    if sys.platform != "darwin":
        raise InstallError("Atomic app installation requires macOS.")
    library = ctypes.CDLL(None, use_errno=True)
    operation = library.renamex_np
    operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    operation.restype = ctypes.c_int
    if operation(os.fsencode(source), os.fsencode(destination), flag):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def save(directory, state):
    temporary = directory / "transaction.json.tmp"
    with temporary.open("w") as file:
        json.dump(state, file)
        file.flush()
        os.fsync(file.fileno())
    temporary.replace(directory / "transaction.json")


def prepare(source, destination):
    source, destination = absolute_path(source), absolute_path(destination)
    if source == destination:
        raise InstallError("Source and destination must differ.")
    source_requirement = validate_bundle(source)
    previous = snapshot(destination)
    if previous is not None:
        previous_requirement = validate_bundle(destination)
        check_compatibility(source, source_requirement, destination, previous_requirement)
    directory = Path(tempfile.mkdtemp(prefix=PREFIX, dir=destination.parent))
    try:
        staged = directory / destination.name
        run("/usr/bin/ditto", str(source), str(staged))
        staged_requirement = validate_bundle(staged)
        check_compatibility(source, source_requirement, staged, staged_requirement)
        if snapshot(destination) != previous:
            raise InstallError("Installed app changed while preparing the update; retry installation.")
        save(directory, {"destination": str(destination), "previous": previous,
                         "replacement": snapshot(staged), "phase": "prepared"})
        return directory
    except BaseException:
        shutil.rmtree(directory)
        raise


def load(directory, destination):
    directory, destination = absolute_path(directory), absolute_path(destination)
    if directory.is_symlink() or not directory.name.startswith(PREFIX) or directory.parent != destination.parent:
        raise InstallError("Invalid installation staging directory.")
    with (directory / "transaction.json").open() as file:
        state = json.load(file)
    if state.get("destination") != str(destination):
        raise InstallError("Staging directory belongs to another destination.")
    return directory, destination, directory / destination.name, state


def rollback(directory, destination):
    directory, destination, staged, state = load(directory, destination)
    current, waiting = snapshot(destination), snapshot(staged)
    if current == state["previous"] and waiting == state["replacement"]:
        return  # Preparation only, or an already restored update.
    if current != state["replacement"] or waiting != state["previous"]:
        raise InstallError(f"App paths changed; preserving recovery files in {directory}")
    if state["previous"] is None:
        rename(destination, staged, RENAME_EXCL)
    else:
        rename(staged, destination, RENAME_SWAP)
    state["phase"] = "rolled_back"
    save(directory, state)


def install(directory, destination):
    directory, destination, staged, state = load(directory, destination)
    if snapshot(destination) != state["previous"] or snapshot(staged) != state["replacement"]:
        raise InstallError(f"App paths changed after preflight; preserving {directory}")
    requirement = validate_bundle(staged)
    if state["previous"] is not None:
        previous_requirement = validate_bundle(destination)
        check_compatibility(staged, requirement, destination, previous_requirement)
    # Signature checks can take time. Do not swap in a bundle whose path was changed
    # while they ran, or overwrite another install that completed during validation.
    if snapshot(destination) != state["previous"] or snapshot(staged) != state["replacement"]:
        raise InstallError(f"App paths changed during validation; preserving {directory}")
    try:
        rename(staged, destination, RENAME_SWAP if state["previous"] is not None else RENAME_EXCL)
        if snapshot(destination) != state["replacement"] or snapshot(staged) != state["previous"]:
            raise InstallError(f"App paths changed during replacement; preserving {directory}")
        validate_bundle(destination)
        if snapshot(destination) != state["replacement"] or snapshot(staged) != state["previous"]:
            raise InstallError(f"App paths changed during final validation; preserving {directory}")
        state["phase"] = "installed"
        save(directory, state)
    except BaseException as error:
        try:
            rollback(directory, destination)
        except BaseException as recovery_error:
            raise InstallError(f"Installation failed ({error}); rollback failed ({recovery_error}). "
                               f"Preserved recovery files: {directory}") from error
        raise


def discard(directory, destination, finished=False):
    directory, destination, staged, state = load(directory, destination)
    current, waiting = snapshot(destination), snapshot(staged)
    expected = ((state["replacement"], state["previous"]) if finished
                else (state["previous"], state["replacement"]))
    if (current, waiting) != expected:
        raise InstallError(f"Refusing to remove recovery files: {directory}")
    if finished:
        validate_bundle(destination)
    shutil.rmtree(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "install", "rollback", "finish", "discard"])
    parser.add_argument("source_or_staging")
    parser.add_argument("destination")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            print(prepare(args.source_or_staging, args.destination))
        elif args.command == "install":
            install(args.source_or_staging, args.destination)
        elif args.command == "rollback":
            rollback(args.source_or_staging, args.destination)
        else:
            discard(args.source_or_staging, args.destination, finished=args.command == "finish")
    except (InstallError, OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
