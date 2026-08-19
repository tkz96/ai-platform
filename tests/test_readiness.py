from pathlib import Path
from unittest.mock import patch

from ai_platform.setup.readiness import (
    check_deploy_readiness,
    check_empirical_phase_status,
    check_network_readiness,
    check_podman_readiness,
    check_render_readiness,
    check_secrets_readiness,
    check_verify_readiness,
)


def test_check_podman_readiness_stopped(tmp_path: Path):
    with (
        patch("shutil.which", return_value="/usr/local/bin/podman"),
        patch("subprocess.run") as mock_run,
    ):
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = '[{"Name": "ai-platform", "Running": false}]'
        status, details, err = check_podman_readiness(tmp_path)
        assert status == "pending"
        assert details["machine_exists"] is True
        assert details["running"] is False


def test_check_podman_readiness_running_and_responsive(tmp_path: Path):
    with (
        patch("shutil.which", return_value="/usr/local/bin/podman"),
        patch("subprocess.run") as mock_run,
    ):

        def side_effect(cmd, **kwargs):
            if "machine" in cmd:
                return type(
                    "CompletedProcess",
                    (),
                    {"returncode": 0, "stdout": '[{"Name": "ai-platform", "Running": true}]'},
                )()
            elif "info" in cmd:
                return type("CompletedProcess", (), {"returncode": 0, "stdout": "Host: Mac"})()
            return type("CompletedProcess", (), {"returncode": 0, "stdout": ""})()

        mock_run.side_effect = side_effect
        status, details, err = check_podman_readiness(tmp_path)
        assert status == "completed"
        assert details["running"] is True
        assert details["info_ok"] is True
        assert err is None


def test_check_network_readiness_satisfied(tmp_path: Path):
    # Setup mock files
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True)
    (state_dir / "dnsmasq.conf").write_text("interface=en0\n")

    with (
        patch("subprocess.run") as mock_run,
        patch("pathlib.Path.exists", return_value=True),
        patch("pathlib.Path.read_text", return_value="12345"),
        patch("os.kill", return_value=None),
    ):

        def side_effect(cmd, **kwargs):
            cmd_str = " ".join(cmd)
            if "ifconfig" in cmd_str:
                return type(
                    "CompletedProcess",
                    (),
                    {"returncode": 0, "stdout": "inet 10.42.0.1 netmask 0xffffff00"},
                )()
            elif "route" in cmd_str:
                return type(
                    "CompletedProcess",
                    (),
                    {"returncode": 0, "stdout": "interface: en0\ngateway: 192.168.1.1"},
                )()
            elif "dnsmasq" in cmd_str:
                return type(
                    "CompletedProcess", (), {"returncode": 0, "stdout": "syntax check OK"}
                )()
            elif "sysctl" in cmd_str:
                return type("CompletedProcess", (), {"returncode": 0, "stdout": "1"})()
            elif "pfctl" in cmd_str:
                return type(
                    "CompletedProcess", (), {"returncode": 0, "stdout": "Status: Enabled"}
                )()
            return type("CompletedProcess", (), {"returncode": 0, "stdout": ""})()

        mock_run.side_effect = side_effect
        status, details, err = check_network_readiness(tmp_path)
        assert status == "completed"
        assert details["ip_10_42_0_1"] is True
        assert details["dhcp_ok"] is True
        assert details["nat_ok"] is True
        assert err is None


def test_check_secrets_readiness(tmp_path: Path):
    # Missing initially
    status, details, err = check_secrets_readiness(tmp_path)
    assert status == "pending"

    # Create valid .env and cluster SSH key
    (tmp_path / ".env").write_text("POSTGRES_PASSWORD=test" + ("x" * 120))
    ssh_dir = tmp_path / "secrets" / "ssh"
    ssh_dir.mkdir(parents=True)
    (ssh_dir / "cluster_orchestrator_key").write_text("PRIVATE_KEY_DATA")

    status, details, err = check_secrets_readiness(tmp_path)
    assert status == "completed"
    assert details["env_file_exists"] is True
    assert details["cluster_ssh_key_exists"] is True
    assert err is None


def test_check_render_readiness(tmp_path: Path):
    status, details, err = check_render_readiness(tmp_path)
    assert status == "pending"

    (tmp_path / "compose.yaml").write_text("services: {}")
    caddy_dir = tmp_path / "configs" / "caddy"
    caddy_dir.mkdir(parents=True)
    (caddy_dir / "Caddyfile").write_text(":8080")

    litellm_dir = tmp_path / "configs" / "litellm"
    litellm_dir.mkdir(parents=True)
    (litellm_dir / "config.yaml").write_text("model_list: []")

    status, details, err = check_render_readiness(tmp_path)
    assert status == "completed"
    assert details["compose_yaml_exists"] is True


def test_check_deploy_readiness(tmp_path: Path):
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "postgres\nredis\nclickhouse\nlangfuse\nlitellm\ncaddy\n"
        status, details, err = check_deploy_readiness(tmp_path)
        assert status == "completed"
        assert len(details["matched_services"]) == 6
        assert err is None


def test_check_verify_readiness(tmp_path: Path):
    with patch("socket.create_connection") as mock_conn:
        mock_conn.return_value.__enter__.return_value = None
        status, details, err = check_verify_readiness(tmp_path)
        assert status == "completed"
        assert details["open_ports"] == 6
        assert err is None


def test_check_empirical_phase_status_dispatch(tmp_path: Path):
    status, _, _ = check_empirical_phase_status("unknown-phase", tmp_path)
    assert status == "pending"
