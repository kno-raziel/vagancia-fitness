"""Synthetic CLI fixtures: no Xcode, simulator, or device operations occur."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("simulator_destinations", SCRIPTS / "_simulator_destinations.py")
SIMULATORS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIMULATORS)


def device(udid="eligible", name="iPhone 17 Pro", available=True, state="Shutdown"):
    return {"udid": udid, "name": name, "isAvailable": available, "state": state}


DESTINATIONS = """Available destinations for the scheme:
    { platform:iOS Simulator, arch:arm64, id:eligible, OS:26.2, name:iPhone 17 Pro }
    { platform:iOS Simulator, arch:arm64, id:old, OS:18.0, name:iPhone 16 }
    { platform:iOS Simulator, arch:arm64, id:tablet, OS:26.2, name:iPad Pro }
Ineligible destinations for the scheme:
    { platform:iOS Simulator, id:ineligible, name:iPhone 17, error:Runtime is unavailable }
"""


class SimulatorFixtures(unittest.TestCase):
    def setUp(self):
        self.inventory = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                device(), device("ineligible"), device("not-in-scheme"),
                device("unavailable", available=False), device("tablet", "iPad Pro"),
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [device("old", "iPhone 16")],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [device("tv")],
        }}

    def test_counts_only_ios26_iphones_in_both_inventories(self):
        devices = SIMULATORS.usable_devices(self.inventory, DESTINATIONS)
        self.assertEqual([entry["udid"] for entry in devices], ["eligible"])
        self.assertEqual(SIMULATORS.select_destination(devices, ""), "platform=iOS Simulator,id=eligible")

    def test_explicit_destination_cannot_bypass_preflight(self):
        devices = SIMULATORS.usable_devices(self.inventory, DESTINATIONS)
        for requested in (
            "platform=iOS Simulator,id=ineligible", "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1",
            "platform=iOS,id=eligible", "platform=iOS Simulator,unsupported=value",
            "platform=iOS Simulator,id=eligible,id=other",
            "platform=iOS Simulator,id=eligible,arch=unsupported",
        ):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                SIMULATORS.select_destination(devices, requested)

    def test_explicit_name_and_os_resolve_to_validated_id(self):
        devices = SIMULATORS.usable_devices(self.inventory, DESTINATIONS)
        self.assertEqual(SIMULATORS.select_destination(
            devices, "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2"),
            "platform=iOS Simulator,id=eligible")

    def test_booted_preference_is_deterministic(self):
        self.inventory["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-2"].append(
            device("booted", "iPhone 17", state="Booted"))
        destinations = DESTINATIONS.replace("Ineligible destinations", "{ platform:iOS Simulator, id:booted }\nIneligible destinations")
        devices = SIMULATORS.usable_devices(self.inventory, destinations)
        self.assertEqual(devices[0]["udid"], "booted")

    def test_latest_os_is_selected_explicitly(self):
        devices = [device("old"), {**device("new"), "OS": "26.4"}]
        devices[0]["OS"] = "26.2"
        self.assertEqual(SIMULATORS.select_destination(devices, "platform=iOS Simulator,OS=latest"),
                         "platform=iOS Simulator,id=new")


MOCK_TOOL = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
if name == "xcodegen":
    print("Version: 2.44.1")
elif name == "xcrun":
    if args[:2] == ["--find", "swift"]:
        print("/mock/swift")
    elif args[:2] == ["swift", "--version"]:
        print("Apple Swift version " + os.environ.get("MOCK_SWIFT", "6.2.1") + " (mock)")
    elif args[:2] == ["swift", "format"]:
        print("602.0.0")
    elif args[:2] == ["simctl", "list"]:
        if os.environ.get("MOCK_SIMCTL_FAILURE"):
            print("Synthetic CoreSimulator failure", file=sys.stderr)
            sys.exit(9)
        print(os.environ["MOCK_INVENTORY"])
elif name == "xcodebuild":
    if args == ["-version"]:
        print("Xcode " + os.environ.get("MOCK_XCODE", "26.1.1"))
    elif "-showdestinations" in args:
        if os.environ.get("MOCK_SHOW_FAILURE"):
            print("Synthetic destination failure", file=sys.stderr)
            sys.exit(10)
        print(os.environ["MOCK_DESTINATIONS"])
    elif "test" in args and any("-only-testing:" + target in args for target in os.environ.get("MOCK_FAIL_TARGETS", "").split(",") if target):
        sys.exit(65)
'''


class WrapperFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        apple = self.root / "apple"
        self.scripts = apple / "scripts"
        self.scripts.mkdir(parents=True)
        for name in ("_common.sh", "_simulator_destinations.py", "doctor", "build", "test"):
            shutil.copy2(SCRIPTS / name, self.scripts / name)
        for name in ("Config/Development.xcconfig", "Config/HealthKit.entitlements", "project.yml", "VaganciaFitness.xcodeproj/project.pbxproj"):
            path = apple / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("xcodebuild", "xcrun", "xcodegen"):
            path = self.bin / name
            path.write_text("#!" + sys.executable + "\n" + MOCK_TOOL)
            path.chmod(0o755)
        self.calls_path = self.root / "calls.jsonl"
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "MOCK_CALLS": str(self.calls_path), "MOCK_DESTINATIONS": DESTINATIONS,
                    "MOCK_INVENTORY": json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-2": [device()]}})}
        for name in ("CONFIGURATION", "DESTINATION", "EXPECTED_XCODE_VERSION", "EXPECTED_SWIFT_VERSION"):
            self.env.pop(name, None)

    def run_wrapper(self, name, *arguments):
        return subprocess.run([str(self.scripts / name), *arguments], env=self.env,
                              capture_output=True, text=True, check=False)

    def calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()] if self.calls_path.exists() else []

    def test_debug_is_default_and_release_is_forwarded_for_every_app(self):
        for configuration in ("Debug", "Release"):
            self.env["CONFIGURATION"] = configuration
            for scheme in ("VaganciaFitness", "VaganciaFitnessDebug", "VaganciaFitnessWatch"):
                result = self.run_wrapper("build", scheme)
                self.assertEqual(result.returncode, 0, result.stderr)
                call = self.calls()[-1]
                self.assertEqual(call[call.index("-configuration") + 1], configuration)
                self.assertIn("CODE_SIGNING_ALLOWED=NO", call)
                self.assertEqual(call[-1], "build")
        self.env.pop("CONFIGURATION")
        self.assertEqual(self.run_wrapper("build").returncode, 0)
        self.assertEqual(self.calls()[-1][self.calls()[-1].index("-configuration") + 1], "Debug")

    def test_invalid_configuration_fails_before_build_or_test(self):
        self.env["CONFIGURATION"] = "Production"
        for wrapper in ("build", "test"):
            result = self.run_wrapper(wrapper)
            self.assertEqual(result.returncode, 2)
            self.assertIn("Use Debug or Release", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_all_aggregates_failures_and_attempts_every_independent_suite(self):
        self.env["MOCK_FAIL_TARGETS"] = "FitnessCoreTests,VaganciaFitnessUITests"
        result = self.run_wrapper("test", "all")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Failed test groups: core ui-product", result.stderr)
        tests = [call for call in self.calls() if call[-1] == "test"]
        self.assertEqual(len(tests), 5)
        self.assertEqual([next(arg for arg in call if arg.startswith("-only-testing:")) for call in tests], [
            "-only-testing:FitnessCoreTests", "-only-testing:FitnessRuntimeTests",
            "-only-testing:VaganciaFitnessWatchCallbackTests", "-only-testing:VaganciaFitnessUITests",
            "-only-testing:VaganciaFitnessDebugUITests"])

    def test_all_success_and_release_forwarding(self):
        self.env["CONFIGURATION"] = "Release"
        result = self.run_wrapper("test", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        tests = [call for call in self.calls() if call[-1] == "test"]
        self.assertEqual(len(tests), 5)
        self.assertTrue(all(call[call.index("-configuration") + 1] == "Release" for call in tests))

    def test_custom_test_selection_is_preserved(self):
        result = self.run_wrapper("test", "core", "-only-testing:FitnessCoreTests/Synthetic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([arg for arg in self.calls()[-1] if arg.startswith("-only-testing:")],
                         ["-only-testing:FitnessCoreTests/Synthetic"])

    def test_test_preflight_rejects_wrong_os_before_test(self):
        self.env["DESTINATION"] = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1"
        result = self.run_wrapper("test", "core")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No usable iOS 26+", result.stderr)
        self.assertFalse(any(call[-1] == "test" for call in self.calls()))

    def test_preflight_failures_are_actionable(self):
        for failure in ("MOCK_SIMCTL_FAILURE", "MOCK_SHOW_FAILURE"):
            self.env[failure] = "1"
            result = self.run_wrapper("test", "core")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Synthetic", result.stderr)
            self.assertIn("DEVELOPER_DIR", result.stderr)
            self.assertIn("never downloads runtimes", result.stderr)
            self.env.pop(failure)

    def test_malformed_inventory_reports_preflight_failure(self):
        for inventory in ("invalid JSON", "[]", '{"devices": []}'):
            self.env["MOCK_INVENTORY"] = inventory
            result = self.run_wrapper("test", "core")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Simulator preflight failed", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_doctor_accepts_local_and_exact_ci_versions(self):
        result = self.run_wrapper("doctor")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("usable iOS 26+ iPhone simulators: 1", result.stdout)
        self.env.update({"MOCK_XCODE": "26.2", "MOCK_SWIFT": "6.2.3",
                         "EXPECTED_XCODE_VERSION": "26.2", "EXPECTED_SWIFT_VERSION": "6.2.3"})
        self.assertEqual(self.run_wrapper("doctor").returncode, 0)
        self.env["EXPECTED_XCODE_VERSION"] = "26.1.1"
        result = self.run_wrapper("doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected 26.1.1, found 26.2", result.stdout)

    def test_doctor_rejects_only_old_simulators(self):
        self.env["MOCK_INVENTORY"] = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [device("old")]}})
        result = self.run_wrapper("doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("usable iOS 26+ iPhone simulators: 0", result.stdout)
        self.assertIn("no compatible iPhone simulator", result.stdout)

    def test_doctor_reports_python_missing_explicitly(self):
        for name in ("dirname", "head", "sed"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env["PATH"] = str(self.bin)
        result = self.run_wrapper("doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing  Python 3", result.stdout)
        self.assertNotIn("python3: command not found", result.stderr)

    def test_doctor_rejects_old_python_before_simulator_preflight(self):
        python = self.bin / "python3"
        python.write_text("#!" + sys.executable + "\nprint('3.10.16')\nraise SystemExit(1)\n")
        python.chmod(0o755)
        result = self.run_wrapper("doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Python requires 3.11 or newer, found 3.10.16", result.stdout)
        self.assertFalse(any("-showdestinations" in call for call in self.calls()))


if __name__ == "__main__":
    unittest.main()
