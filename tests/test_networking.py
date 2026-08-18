import os
import subprocess
import tempfile
import pytest
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
NETWORKING_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "networking.sh"


def run_bash_func(func_call: str) -> subprocess.CompletedProcess:
    script = f"""
    export PROJECT_ROOT="{PROJECT_ROOT}"
    source "{NETWORKING_LIB}"
    {func_call}
    """
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True)


def test_dnsmasq_pid_path_in_networking_sh():
    content = NETWORKING_LIB.read_text()
    assert "/tmp/ai-platform-dnsmasq.pid" in content
    assert "dnsmasq.pid" not in content.replace("/tmp/ai-platform-dnsmasq.pid", "")


def test_stop_mac_dhcp_server_verifies_process_identity():
    content = NETWORKING_LIB.read_text()
    # Check that stop_mac_dhcp_server verifies process identity using ps command check
    assert "ps -p" in content
    assert "dnsmasq.conf" in content


def test_start_mac_dhcp_server_captures_stderr():
    content = NETWORKING_LIB.read_text()
    assert "2>\"$err_file\"" in content or "2>\"$state_dir/dnsmasq.err\"" in content
    assert "render_diagnostic_box" in content


def test_setup_dnsmasq_config_valid():
    with tempfile.TemporaryDirectory() as tmpdir:
        res = run_bash_func(f"PROJECT_ROOT='{tmpdir}' setup_dnsmasq_config en0")
        assert res.returncode == 0
        conf_file = Path(tmpdir) / "state" / "dnsmasq.conf"
        assert conf_file.exists()
        assert "interface=en0" in conf_file.read_text()
