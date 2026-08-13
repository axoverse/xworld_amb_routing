"""
pytest configuration and fixtures for xworld_xbase_plugin tests.
"""

import subprocess
import shutil
import sys
from pathlib import Path
import pytest

# Add the scripts directory to the Python path
scripts_dir = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(scripts_dir))


def pytest_addoption(parser):
    """Add custom command line options."""
    parser.addoption(
        "--glb",
        action="store",
        default=None,
        help="Path to a specific GLB file to validate"
    )
    parser.addoption(
        "--expected",
        action="store",
        default=None,
        help="Path to expected values JSON file"
    )
    parser.addoption(
        "--skip-export",
        action="store_true",
        default=False,
        help="Skip auto-export of fixtures before validation tests"
    )


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "gltf_validation: marks tests that validate GLTF exports"
    )


def find_godot_executable() -> str:
    """Find Godot executable in PATH."""
    for name in ["godot", "godot4", "godot.exe", "Godot_v4.4-stable_win64.exe"]:
        path = shutil.which(name)
        if path:
            return path
    return ""


def get_project_dir() -> Path:
    """Get the Godot project directory (godot_proj)."""
    # This file is in share/tests/, godot_proj is 5 levels up
    return Path(__file__).parent.parent.parent.parent.parent


def get_output_dir() -> Path:
    """Get the tests/output directory."""
    return Path(__file__).parent.parent.parent / "tests" / "output"


@pytest.fixture(scope="session")
def godot_executable() -> str:
    """Get Godot executable path or skip tests that need it."""
    exe = find_godot_executable()
    if not exe:
        pytest.skip("Godot executable not found in PATH")
    return exe


@pytest.fixture(scope="session", autouse=True)
def ensure_gltf_exports(request):
    """
    Auto-export test fixtures before GLTF validation tests.
    
    This runs once per test session before any gltf_validation tests.
    Skip with --skip-export.
    """
    if request.config.getoption("--skip-export"):
        return
    
    # Check if we're running gltf_validation tests
    # Only run export if we have validation tests selected
    items = request.session.items if hasattr(request.session, 'items') else []
    has_validation_tests = any(
        "gltf_validation" in str(item.keywords) or "test_gltf_validation" in str(item.fspath)
        for item in items
    )
    
    if not has_validation_tests:
        return
    
    godot_exe = find_godot_executable()
    if not godot_exe:
        print("\nWARNING: Godot not found, skipping auto-export")
        return
    
    project_dir = get_project_dir()
    output_dir = get_output_dir()
    
    # Check if exports already exist and are recent
    gltf_files = list(output_dir.glob("*.gltf")) if output_dir.exists() else []
    if len(gltf_files) >= 4:
        # Exports exist, skip re-export
        print(f"\nUsing existing exports in {output_dir}")
        return
    
    print(f"\nExporting test fixtures using Godot...")
    
    result = subprocess.run(
        [
            godot_exe,
            "--headless",
            "--editor",
            "--script", "res://addons/xbase_plugin/tests/test_runner.gd",
            "--", "--export-only"
        ],
        cwd=str(project_dir),
        capture_output=True,
        text=True,
        timeout=120
    )
    
    if result.returncode != 0:
        print(f"Export warning (exit {result.returncode}):")
        print(result.stderr[-500:] if result.stderr else "No stderr")
    else:
        print("Export completed successfully")


@pytest.fixture
def data_dir() -> Path:
    """Return the path to the shared data directory."""
    return Path(__file__).parent.parent / "data"


@pytest.fixture
def physical_types_json(data_dir: Path) -> Path:
    """Return path to physical_types.json."""
    return data_dir / "physical_types.json"


@pytest.fixture
def layers_json(data_dir: Path) -> Path:
    """Return path to layers.json."""
    return data_dir / "layers.json"


@pytest.fixture
def edges_json(data_dir: Path) -> Path:
    """Return path to edges.json."""
    return data_dir / "edges.json"


@pytest.fixture
def fixtures_dir() -> Path:
    """Return the path to test fixtures directory."""
    return Path(__file__).parent.parent.parent / "tests" / "fixtures"


@pytest.fixture
def output_dir() -> Path:
    """Return the path to test output directory."""
    return get_output_dir()


@pytest.fixture
def expected_extras(fixtures_dir: Path):
    """Load expected_extras.json."""
    import json
    expected_path = fixtures_dir / "expected_extras.json"
    if expected_path.exists():
        with open(expected_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {}


@pytest.fixture
def sample_gltf_path(tmp_path: Path) -> Path:
    """Create a minimal GLTF file for testing."""
    import json
    
    gltf_content = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {"name": "RootNode"},
            {"name": "Room_101"},
            {"name": "Bed_101"},
        ]
    }
    
    gltf_path = tmp_path / "test.gltf"
    with open(gltf_path, 'w') as f:
        json.dump(gltf_content, f)
    
    return gltf_path
