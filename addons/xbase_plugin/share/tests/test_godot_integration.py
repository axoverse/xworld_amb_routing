"""
Godot test integration - wraps Godot tests to run via pytest.

These tests require Godot to be installed and available in PATH.
Run with: pytest -m godot
"""

import subprocess
import shutil
import re
from pathlib import Path
import pytest


# Mark all tests in this module as requiring Godot
pytestmark = pytest.mark.godot


def find_godot_executable() -> str:
    """Find Godot executable in PATH."""
    for name in ["godot", "godot4", "godot.exe", "Godot_v4.4-stable_win64.exe"]:
        path = shutil.which(name)
        if path:
            return path
    return ""


def get_project_root() -> Path:
    """Get the xbase_plugin project root directory."""
    # This file is in share/tests/, plugin root is two levels up
    return Path(__file__).parent.parent.parent


@pytest.fixture(scope="module")
def godot_executable() -> str:
    """Get Godot executable path or skip tests."""
    exe = find_godot_executable()
    if not exe:
        pytest.skip("Godot executable not found in PATH")
    return exe


@pytest.fixture(scope="module")
def godot_project_dir() -> Path:
    """Get the Godot project directory."""
    # xbase_plugin is in godot_proj/addons/xbase_plugin
    # godot_proj is three levels up from share/tests/
    return Path(__file__).parent.parent.parent.parent.parent


class TestGodotAvailability:
    """Tests for Godot availability."""
    
    def test_godot_executable_exists(self, godot_executable: str):
        """Godot executable should be found."""
        assert godot_executable, "Godot executable not found"
    
    def test_godot_version(self, godot_executable: str):
        """Godot should report its version."""
        result = subprocess.run(
            [godot_executable, "--version"],
            capture_output=True,
            text=True,
            timeout=30
        )
        assert result.returncode == 0 or "4." in result.stdout


class TestGodotUnitTests:
    """Run Godot unit tests via subprocess."""
    
    def test_run_godot_unit_tests(self, godot_executable: str, godot_project_dir: Path):
        """Run the Godot test runner and verify it passes."""
        test_script = "res://addons/xbase_plugin/tests/test_runner.gd"
        
        result = subprocess.run(
            [
                godot_executable,
                "--headless",
                "--editor",
                "--script", test_script,
                "--", "--unit"
            ],
            cwd=str(godot_project_dir),
            capture_output=True,
            text=True,
            timeout=120
        )
        
        # Parse output for test results
        output = result.stdout + result.stderr
        
        # Check for pass/fail in output
        passed_match = re.search(r"Passed:\s*(\d+)", output)
        failed_match = re.search(r"Failed:\s*(\d+)", output)
        
        if passed_match and failed_match:
            passed = int(passed_match.group(1))
            failed = int(failed_match.group(1))
            
            print(f"\nGodot Unit Tests: {passed} passed, {failed} failed")
            
            if failed > 0:
                # Print the output for debugging
                print("\n--- Godot Test Output ---")
                print(output[-2000:] if len(output) > 2000 else output)
                pytest.fail(f"Godot unit tests failed: {failed} failures")
        else:
            # If we can't parse output, check exit code
            if result.returncode != 0 and "All tests passed" not in output:
                print("\n--- Godot Output ---")
                print(output[-2000:] if len(output) > 2000 else output)
                pytest.fail(f"Godot tests may have failed (exit code {result.returncode})")
    
    def test_run_godot_integration_tests(self, godot_executable: str, godot_project_dir: Path):
        """Run Godot integration tests for AMB_Hospital.tscn."""
        test_script = "res://addons/xbase_plugin/tests/test_runner.gd"
        
        result = subprocess.run(
            [
                godot_executable,
                "--headless",
                "--editor",
                "--script", test_script,
                "--", "--scene=res://amb/AMB_Hospital.tscn"
            ],
            cwd=str(godot_project_dir),
            capture_output=True,
            text=True,
            timeout=180
        )
        
        output = result.stdout + result.stderr
        
        # Check for PASS in output
        if "[PASS]" in output:
            print("\nGodot integration test passed")
        elif "[FAIL]" in output or result.returncode != 0:
            print("\n--- Godot Output ---")
            print(output[-2000:] if len(output) > 2000 else output)
            pytest.fail("Godot integration test failed")


class TestGodotAllTests:
    """Run all Godot tests together."""
    
    @pytest.mark.slow
    def test_run_all_godot_tests(self, godot_executable: str, godot_project_dir: Path):
        """Run all Godot tests (unit + integration)."""
        test_script = "res://addons/xbase_plugin/tests/test_runner.gd"
        
        result = subprocess.run(
            [
                godot_executable,
                "--headless",
                "--editor",
                "--script", test_script,
                "--", "--all"
            ],
            cwd=str(godot_project_dir),
            capture_output=True,
            text=True,
            timeout=300
        )
        
        output = result.stdout + result.stderr
        
        # Parse results
        passed_match = re.search(r"Passed:\s*(\d+)", output)
        failed_match = re.search(r"Failed:\s*(\d+)", output)
        
        if passed_match and failed_match:
            passed = int(passed_match.group(1))
            failed = int(failed_match.group(1))
            
            print(f"\nGodot All Tests: {passed} passed, {failed} failed")
            
            assert failed == 0, f"Godot tests failed: {failed} failures"
            assert passed > 0, "No tests ran"
        else:
            # Fallback: check for success message
            assert "All tests passed" in output, f"Could not verify test results.\nOutput: {output[-1000:]}"

