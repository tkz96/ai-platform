import subprocess
from pathlib import Path
from platform.nodes import (
    ModelAssignment,
    NodeDesiredConfig,
    NodeIdentity,
    NodeRecord,
    NodeRegistry,
    NodeRuntimeState,
    load_registry,
    save_registry,
)
from platform.provisioner import (
    probe_remote_health,
    provision_all_nodes,
    provision_single_node,
)
from typing import Any
from unittest.mock import MagicMock, patch


def test_probe_remote_health_contract() -> None:
    # 1. HTTP 200 with {"status": "ok"}
    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = b'{"status": "ok", "slots": 4}'
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        ok, data, lat = probe_remote_health("10.42.0.2", 8080)
        assert ok is True
        assert data is not None
        assert data["status"] == "ok"

    # 2. HTTP 200 with {"status": "error"} or unexpected payload
    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = b'{"status": "error", "message": "out of memory"}'
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        ok, data, lat = probe_remote_health("10.42.0.2", 8080)
        assert ok is False
        assert data is not None
        assert data["status"] == "error"

    # 3. HTTP 503 (model loading)
    import urllib.error

    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_err = urllib.error.HTTPError(
            url="http://10.42.0.2:8080/health",
            code=503,
            msg="Service Unavailable",
            hdrs={},  # type: ignore[arg-type]
            fp=MagicMock(read=lambda: b'{"status": "loading model"}'),
        )
        mock_urlopen.side_effect = mock_err

        ok, data, lat = probe_remote_health("10.42.0.2", 8080)
        assert ok is False
        assert data is not None
        assert data.get("status") == "loading model"

    # 4. Connection refused / network error
    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.side_effect = ConnectionRefusedError("Connection refused")
        ok, data, lat = probe_remote_health("10.42.0.2", 8080)
        assert ok is False
        assert data is None


def setup_test_repo(tmp_path: Path) -> None:
    repo_root = Path(__file__).parent.parent
    (tmp_path / "platform.yaml").write_text((repo_root / "platform.yaml").read_text())
    (tmp_path / "versions.yaml").write_text((repo_root / "versions.yaml").read_text())

    services_dir = tmp_path / "services"
    services_dir.mkdir(exist_ok=True)
    for f in (repo_root / "services").glob("*.yaml"):
        (services_dir / f.name).write_text(f.read_text())

    templates_dir = tmp_path / "templates" / "inference"
    templates_dir.mkdir(parents=True, exist_ok=True)
    (templates_dir / "llama-server.service.j2").write_text(
        (repo_root / "templates" / "inference" / "llama-server.service.j2").read_text()
    )


def test_provision_skips_enrolled_pending_ip(tmp_path: Path) -> None:
    setup_test_repo(tmp_path)
    # Setup test registry with an enrolled_pending_ip node
    reg = NodeRegistry()
    reg.nodes["node-01"] = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="linux-pc-1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(status="enrolled_pending_ip"),
    )
    save_registry(tmp_path, reg)

    with patch("platform.provisioner.SSHRunner.run_cmd") as mock_ssh:
        results = provision_all_nodes(tmp_path)
        assert "node-01" in results
        assert results["node-01"].get("skipped") is True
        assert "enrolled_pending_ip" in results["node-01"]["reason"]
        # SSHRunner must NOT be invoked for nodes pending IP
        mock_ssh.assert_not_called()


def test_provision_prerequisites_missing(tmp_path: Path) -> None:
    repo_root = Path(__file__).parent.parent
    reg = NodeRegistry()
    node = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="linux-pc-1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(status="enrolled"),
    )
    reg.nodes["node-01"] = node
    save_registry(tmp_path, reg)

    def mock_run_cmd(
        host: str, user: str, command: str, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        if "uname -a" in command:
            return subprocess.CompletedProcess(args=[], returncode=0, stdout="Linux", stderr="")
        if "test -x '/usr/local/bin/llama-server'" in command:
            # Binary missing or not executable
            return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="not found")
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

    with patch("platform.provisioner.SSHRunner.run_cmd", side_effect=mock_run_cmd):
        res = provision_single_node(repo_root, node)
        assert res["success"] is False
        assert node.runtime.status == "prerequisites_missing"
        assert "binary not executable or missing" in (node.runtime.last_error or "")


def test_provision_model_missing(tmp_path: Path) -> None:
    repo_root = Path(__file__).parent.parent
    node = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="linux-pc-1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(
            models=[ModelAssignment(model_name="test-model", model_path="/missing/model.gguf")]
        ),
        runtime=NodeRuntimeState(status="enrolled"),
    )

    def mock_run_cmd(
        host: str, user: str, command: str, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        if "test -f '/missing/model.gguf'" in command:
            # Model file missing
            return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="missing")
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="Linux", stderr="")

    with patch("platform.provisioner.SSHRunner.run_cmd", side_effect=mock_run_cmd):
        res = provision_single_node(repo_root, node)
        assert res["success"] is False
        assert node.runtime.status == "model_missing"
        assert "model file missing" in (node.runtime.last_error or "")


def test_provision_success_and_readiness() -> None:
    repo_root = Path(__file__).parent.parent
    node = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="linux-pc-1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(
            models=[ModelAssignment(model_name="qwen-test", model_path="/home/ubuntu/model.gguf")]
        ),
        runtime=NodeRuntimeState(status="enrolled"),
    )

    def mock_run_cmd(
        host: str, user: str, command: str, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        if "systemctl is-active" in command:
            return subprocess.CompletedProcess(args=[], returncode=0, stdout="active\n", stderr="")
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="Linux", stderr="")

    mock_health = (True, {"status": "ok", "model": "qwen"}, 4.2)
    with (
        patch("platform.provisioner.SSHRunner.run_cmd", side_effect=mock_run_cmd),
        patch("platform.provisioner.SSHRunner.scp_file"),
        patch("platform.provisioner.check_tcp_port", return_value=True),
        patch("platform.provisioner.probe_remote_health", return_value=mock_health),
    ):
        res = provision_single_node(repo_root, node)
        assert res["success"] is True
        assert node.runtime.status == "ready"
        assert node.runtime.systemd_active is True
        assert node.runtime.tcp_open is True
        assert node.runtime.http_healthy is True
        assert node.runtime.health_response == {"status": "ok", "model": "qwen"}
        assert node.runtime.active_model == "qwen-test"


def test_provision_fault_isolation(tmp_path: Path) -> None:
    setup_test_repo(tmp_path)
    # Setup 2 nodes: node-01 will fail with offline SSH, node-02 will succeed
    reg = NodeRegistry()
    node1 = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="bad-pc",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(status="enrolled"),
    )
    node2 = NodeRecord(
        identity=NodeIdentity(
            id="node-02",
            hostname="good-pc",
            mac_address="00:aa:bb:cc:dd:ee",
            reserved_ip="10.42.0.3",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(status="enrolled"),
    )
    reg.nodes["node-01"] = node1
    reg.nodes["node-02"] = node2
    save_registry(tmp_path, reg)

    def mock_run_cmd(
        host: str, user: str, command: str, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        if host == "10.42.0.2":
            # node-01 fails SSH
            return subprocess.CompletedProcess(
                args=[], returncode=255, stdout="", stderr="Host unreachable"
            )
        if "systemctl is-active" in command:
            return subprocess.CompletedProcess(args=[], returncode=0, stdout="active\n", stderr="")
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="Linux", stderr="")

    mock_health = (True, {"status": "ok"}, 2.5)
    with (
        patch("platform.provisioner.SSHRunner.run_cmd", side_effect=mock_run_cmd),
        patch("platform.provisioner.SSHRunner.scp_file"),
        patch("platform.provisioner.check_tcp_port", return_value=True),
        patch("platform.provisioner.probe_remote_health", return_value=mock_health),
    ):
        results = provision_all_nodes(tmp_path)
        assert results["node-01"]["success"] is False
        assert results["node-02"]["success"] is True

        # Verify persisted registry in state/nodes.yaml has updated state for both nodes
        reloaded = load_registry(tmp_path)
        assert reloaded.nodes["node-01"].runtime.status == "offline"
        assert reloaded.nodes["node-02"].runtime.status == "ready"
