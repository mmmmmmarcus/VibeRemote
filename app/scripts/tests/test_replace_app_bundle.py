#!/usr/bin/env python3
"""Installer regression tests; only disposable directories and a simulated signer."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "replace_app_bundle", Path(__file__).resolve().parents[1] / "replace-app-bundle.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


@unittest.skipUnless(sys.platform == "darwin", "Exercises Darwin atomic rename flags")
class ReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vvhisper-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source.app"
        self.destination = self.root / "vvhisper.app"
        self.bundle(self.source, "new")
        self.bundle(self.destination, "old")
        patch = mock.patch.object(installer, "run", side_effect=self.fake_signer)
        patch.start()
        self.addCleanup(patch.stop)

    def bundle(self, path, content, team=installer.TEAM_ID, requirement="stable-personal"):
        (path / "Contents").mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": installer.BUNDLE_ID,
                          "CFBundleExecutable": installer.EXECUTABLE}, file)
        (path / "payload").write_text(content)
        (path / "test-signature.json").write_text(json.dumps(
            {"team": team, "requirement": requirement, "valid": True}))

    def signature(self, path, **changes):
        file = path / "test-signature.json"
        state = json.loads(file.read_text())
        state.update(changes)
        file.write_text(json.dumps(state))

    def fake_signer(self, *arguments):
        if arguments[0] == "/usr/bin/ditto":
            shutil.copytree(arguments[1], arguments[2])
            return ""
        self.assertEqual(arguments[0], "/usr/bin/codesign")
        path = Path(arguments[-1])
        signature = json.loads((path / "test-signature.json").read_text())
        if "--display" in arguments:
            return "designated => " + signature["requirement"]
        self.assertIn("--verify", arguments)
        requirement = next(arg[3:] for arg in arguments if arg.startswith("-R="))
        valid = signature["valid"]
        if requirement == installer.PERSONAL_REQUIREMENT:
            valid = valid and signature["team"] == installer.TEAM_ID
        else:
            valid = valid and requirement == signature["requirement"]
        if not valid:
            raise installer.InstallError("simulated signature rejection")
        return ""

    def prepare(self):
        return installer.prepare(self.source, self.destination)

    def assert_payload(self, path, value):
        self.assertEqual((path / "payload").read_text(), value)

    def test_upgrade_uses_atomic_swap_and_retains_rollback_until_finish(self):
        staging = self.prepare()
        real_rename = installer.rename
        with mock.patch.object(installer, "rename", wraps=real_rename) as rename:
            installer.install(staging, self.destination)
            self.assertEqual(rename.call_args.args[-1], installer.RENAME_SWAP)
        self.assert_payload(self.destination, "new")
        self.assert_payload(staging / self.destination.name, "old")
        installer.discard(staging, self.destination, finished=True)
        self.assertFalse(staging.exists())
        self.assert_payload(self.destination, "new")

    def test_first_install_uses_exclusive_rename_and_can_roll_back(self):
        shutil.rmtree(self.destination)
        staging = self.prepare()
        with mock.patch.object(installer, "rename", wraps=installer.rename) as rename:
            installer.install(staging, self.destination)
            self.assertEqual(rename.call_args.args[-1], installer.RENAME_EXCL)
        installer.rollback(staging, self.destination)
        self.assertFalse(self.destination.exists())
        installer.discard(staging, self.destination)
        self.assertFalse(staging.exists())

    def test_wrong_source_team_fails_before_creating_staging(self):
        self.signature(self.source, team="OTHERTEAM")
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assert_payload(self.destination, "old")
        self.assertEqual(list(self.root.glob(installer.PREFIX + "*")), [])

    def test_wrong_installed_team_fails_before_replacement(self):
        self.signature(self.destination, team="FORMERTEAM")
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assert_payload(self.destination, "old")

    def test_incompatible_requirement_fails_even_on_same_team(self):
        self.signature(self.source, requirement="per-build-hash")
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assert_payload(self.destination, "old")

    def test_invalid_staged_signature_cannot_replace_installed_app(self):
        staging = self.prepare()
        self.signature(staging / self.destination.name, valid=False)
        with self.assertRaises(installer.InstallError):
            installer.install(staging, self.destination)
        self.assert_payload(self.destination, "old")
        installer.discard(staging, self.destination)

    def test_post_swap_validation_failure_restores_original(self):
        staging = self.prepare()
        real_validate = installer.validate_bundle

        def reject_installed_new(path):
            if path == self.destination and (path / "payload").read_text() == "new":
                raise installer.InstallError("post-swap validation failed")
            return real_validate(path)

        with mock.patch.object(installer, "validate_bundle", side_effect=reject_installed_new):
            with self.assertRaises(installer.InstallError):
                installer.install(staging, self.destination)
        self.assert_payload(self.destination, "old")
        self.assert_payload(staging / self.destination.name, "new")
        installer.discard(staging, self.destination)

    def test_rollback_failure_keeps_original_recovery_bundle(self):
        staging = self.prepare()
        real_rename = installer.rename
        calls = 0

        def fail_second_rename(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("simulated rollback failure")
            return real_rename(*args)

        with mock.patch.object(installer, "rename", side_effect=fail_second_rename), \
             mock.patch.object(installer, "save", side_effect=OSError("state write failed")):
            with self.assertRaisesRegex(installer.InstallError, "Preserved recovery files"):
                installer.install(staging, self.destination)
        self.assert_payload(staging / self.destination.name, "old")
        self.assert_payload(self.destination, "new")
        with self.assertRaises(installer.InstallError):
            installer.discard(staging, self.destination)
        installer.rollback(staging, self.destination)
        self.assert_payload(self.destination, "old")

    def test_concurrent_destination_change_is_not_overwritten(self):
        staging = self.prepare()
        self.destination.rename(self.root / "previous.app")
        self.bundle(self.destination, "another-update")
        with self.assertRaises(installer.InstallError):
            installer.install(staging, self.destination)
        self.assert_payload(self.destination, "another-update")
        with self.assertRaises(installer.InstallError):
            installer.discard(staging, self.destination)

    def test_destination_changed_during_validation_is_not_swapped(self):
        staging = self.prepare()
        real_compatibility = installer.check_compatibility

        def update_during_validation(*args):
            real_compatibility(*args)
            self.destination.rename(self.root / "original.app")
            self.bundle(self.destination, "unrelated-update")

        with mock.patch.object(installer, "check_compatibility", side_effect=update_during_validation), \
             mock.patch.object(installer, "rename", wraps=installer.rename) as rename:
            with self.assertRaisesRegex(installer.InstallError, "during validation"):
                installer.install(staging, self.destination)
            rename.assert_not_called()
        self.assert_payload(self.destination, "unrelated-update")
        self.assert_payload(staging / self.destination.name, "new")

    def test_staging_changed_during_validation_is_not_swapped(self):
        staging = self.prepare()
        real_compatibility = installer.check_compatibility

        def update_during_validation(*args):
            real_compatibility(*args)
            staged = staging / self.destination.name
            staged.rename(staging / "original-stage.app")
            self.bundle(staged, "unrelated-staging")

        with mock.patch.object(installer, "check_compatibility", side_effect=update_during_validation), \
             mock.patch.object(installer, "rename", wraps=installer.rename) as rename:
            with self.assertRaisesRegex(installer.InstallError, "during validation"):
                installer.install(staging, self.destination)
            rename.assert_not_called()
        self.assert_payload(self.destination, "old")
        self.assert_payload(staging / self.destination.name, "unrelated-staging")

    def test_race_at_swap_preserves_unexpected_swapped_out_bundle(self):
        staging = self.prepare()
        real_rename = installer.rename

        def update_at_swap(source, destination, flag):
            self.destination.rename(self.root / "original.app")
            self.bundle(self.destination, "unrelated-update")
            real_rename(source, destination, flag)

        with mock.patch.object(installer, "rename", side_effect=update_at_swap):
            with self.assertRaisesRegex(installer.InstallError, "Preserved recovery files"):
                installer.install(staging, self.destination)
        # Never report success or delete a bundle introduced by another installer.
        self.assert_payload(staging / self.destination.name, "unrelated-update")
        self.assert_payload(self.root / "original.app", "old")
        with self.assertRaises(installer.InstallError):
            installer.discard(staging, self.destination, finished=True)

    def test_symlink_destination_is_rejected(self):
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(installer.InstallError, "symlink"):
            self.prepare()
        self.assert_payload(self.source, "new")

    def test_launch_failure_can_restore_prior_bundle(self):
        staging = self.prepare()
        installer.install(staging, self.destination)
        installer.rollback(staging, self.destination)
        installer.rollback(staging, self.destination)  # Idempotent recovery.
        self.assert_payload(self.destination, "old")
        installer.discard(staging, self.destination)

    def test_discard_cannot_remove_another_directory(self):
        with self.assertRaises(installer.InstallError):
            installer.discard(self.source, self.destination)
        self.assert_payload(self.source, "new")


class LaunchVerificationTests(unittest.TestCase):
    """Run a disposable copy of install.sh with all app/build/process commands mocked."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vvhisper-launch-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "scripts").mkdir()
        self.log = self.root / "operations.log"
        self.started = self.root / "launch-requested"
        source = Path(__file__).resolve().parents[2] / "install.sh"
        shutil.copyfile(source, self.root / "install.sh")
        self.write_script(self.root / "create_app_bundle.sh", "exit 0\n")
        (self.root / "scripts/replace-app-bundle.py").write_text(
            "import os, sys\n"
            "with open(os.environ['INSTALL_TEST_LOG'], 'a') as f: f.write(sys.argv[1] + '\\n')\n"
            "if sys.argv[1] == 'prepare': print(os.environ['INSTALL_TEST_STAGING'])\n")
        self.write_script(self.bin / "open", ': > "$INSTALL_TEST_STARTED"\nexit 0\n')
        self.write_script(self.bin / "pgrep",
                          'if [ -f "$INSTALL_TEST_STARTED" ] && [ "$INSTALL_TEST_MODE" != "never" ]; then\n'
                          '  echo 44444\n  exit 0\nfi\nexit 1\n')
        self.write_script(self.bin / "ps",
                          'if [ "$INSTALL_TEST_MODE" = "correct" ]; then\n'
                          '  echo /Applications/vvhisper.app/Contents/MacOS/vvhisper\n'
                          'else\n  echo /temporary/development/vvhisper.app/Contents/MacOS/vvhisper\nfi\n')
        self.write_script(self.bin / "sleep", "exit 0\n")
        self.write_script(self.bin / "osascript", "exit 0\n")
        self.write_script(self.bin / "codesign", "echo TeamIdentifier=Q9MD524YL5\n")

    def write_script(self, path, body):
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_install(self, mode):
        environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                           INSTALL_TEST_LOG=str(self.log), INSTALL_TEST_MODE=mode,
                           INSTALL_TEST_STARTED=str(self.started),
                           INSTALL_TEST_STAGING=str(self.root / "staging"))
        result = subprocess.run(["/bin/bash", str(self.root / "install.sh")],
                                env=environment, capture_output=True, text=True, timeout=10)
        return result, self.log.read_text().splitlines()

    def test_successful_open_without_process_rolls_back(self):
        result, operations = self.run_install("never")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not start", result.stderr)
        self.assertEqual(operations, ["prepare", "install", "rollback", "discard"])

    def test_other_copy_does_not_count_as_installed_process(self):
        result, operations = self.run_install("other-copy")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(operations, ["prepare", "install", "rollback", "discard"])

    def test_observed_exact_installed_process_allows_finish(self):
        result, operations = self.run_install("correct")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(operations, ["prepare", "install", "finish"])


if __name__ == "__main__":
    unittest.main()
