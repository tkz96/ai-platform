import json
import urllib.request
from pathlib import Path

import pytest

from ai_platform.enrollment import make_enrollment_server
from ai_platform.nodes import (
    GPUInfo,
    HardwareSpecs,
    ModelAssignment,
    NodeDesiredConfig,
    NodeIdentity,
    NodeRecord,
    NodeRegistry,
    NodeRuntimeState,
    allocate_next_node_ip,
    generate_dnsmasq_hosts,
    get_healthy_serving_nodes,
    load_registry,
    normalize_mac,
    register_or_update_node,
    save_registry,
    sync_known_hosts,
)


def test_normalize_mac() -> None:
    assert normalize_mac("00:11:22:33:44:55") == "00:11:22:33:44:55"
    assert normalize_mac("00-11-22-33-44-55") == "00:11:22:33:44:55"
    assert normalize_mac("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff"
    assert normalize_mac("  00:11:22:33:44:55 \n") == "00:11:22:33:44:55"


def test_registry_persistence(tmp_path: Path) -> None:
    # Empty registry
    reg = load_registry(tmp_path)
    assert len(reg.nodes) == 0
    assert reg.mac_ip == "10.42.0.1"
    assert reg.subnet == "10.42.0.0/24"

    # Add a node and save
    node = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="test-host",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
            ssh_host_fingerprint="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5TEST",
        ),
        desired=NodeDesiredConfig(
            models=[ModelAssignment(model_name="qwen3.6-35b-a3b", port=8080)]
        ),
        runtime=NodeRuntimeState(status="ready", http_healthy=True, systemd_active=True),
    )
    reg.nodes["node-01"] = node
    save_registry(tmp_path, reg)

    # Reload registry
    reloaded = load_registry(tmp_path)
    assert len(reloaded.nodes) == 1
    assert "node-01" in reloaded.nodes
    assert reloaded.nodes["node-01"].identity.mac_address == "00:11:22:33:44:55"
    assert reloaded.nodes["node-01"].runtime.status == "ready"


def test_corrupted_registry_raises_runtime_error(tmp_path: Path) -> None:
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True)
    corrupted_file = state_dir / "nodes.yaml"

    # Case 1: Malformed YAML syntax
    corrupted_file.write_text("nodes:\n  node-01:\n    identity: {unclosed")
    with pytest.raises(RuntimeError, match="Corrupted node registry"):
        load_registry(tmp_path)

    # Case 2: Schema validation failure
    corrupted_file.write_text("nodes:\n  node-01:\n    identity: 12345")
    with pytest.raises(RuntimeError, match="Corrupted node registry"):
        load_registry(tmp_path)


def test_node_status_values() -> None:
    # Verify all expected status literals work
    statuses = [
        "discovered",
        "enrolled",
        "enrolled_pending_ip",
        "provisioning",
        "ready",
        "model_missing",
        "prerequisites_missing",
        "unhealthy",
        "offline",
    ]
    for st in statuses:
        state = NodeRuntimeState(status=st)  # type: ignore[arg-type]
        assert state.status == st


def test_ip_allocation() -> None:
    reg = NodeRegistry(pool_start="10.42.0.2", pool_size=8)
    id1, ip1 = allocate_next_node_ip(reg)
    assert id1 == "node-01"
    assert ip1 == "10.42.0.2"

    # Add node-01
    reg.nodes["node-01"] = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="h1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
        )
    )
    id2, ip2 = allocate_next_node_ip(reg)
    assert id2 == "node-02"
    assert ip2 == "10.42.0.3"


def test_register_and_re_enrollment() -> None:
    reg = NodeRegistry()
    hw = HardwareSpecs(
        cpu="AMD Ryzen 9",
        ram_gb=64,
        gpus=[GPUInfo(name="NVIDIA RTX 4090", vram_gb=24)],
    )

    # 1. Initial enrollment
    node1, is_new = register_or_update_node(
        registry=reg,
        hostname="gpu-01",
        mac_address="00:11:22:33:44:55",
        ssh_user="ubuntu",
        ssh_host_key="ssh-ed25519 AAAAFINGERPRINT1",
        current_ip="10.42.0.101",
        hardware=hw,
    )
    assert is_new is True
    assert node1.identity.id == "node-01"
    assert node1.identity.reserved_ip == "10.42.0.2"
    assert node1.runtime.hardware.ram_gb == 64

    # 2. Idempotent re-enrollment with same MAC
    node1_again, is_new2 = register_or_update_node(
        registry=reg,
        hostname="gpu-01-renamed",
        mac_address="00:11:22:33:44:55",
        ssh_user="ubuntu",
        ssh_host_key="ssh-ed25519 AAAAFINGERPRINT1",
        current_ip="10.42.0.101",
    )
    assert is_new2 is False
    assert node1_again.identity.id == "node-01"
    assert node1_again.identity.hostname == "gpu-01-renamed"

    # 3. New MAC gets new node ID
    node2, is_new3 = register_or_update_node(
        registry=reg,
        hostname="gpu-02",
        mac_address="00:aa:bb:cc:dd:ee",
        ssh_user="ubuntu",
        ssh_host_key="ssh-ed25519 AAAAFINGERPRINT2",
    )
    assert is_new3 is True
    assert node2.identity.id == "node-02"
    assert node2.identity.reserved_ip == "10.42.0.3"

    # 4. Explicit replacement with replace_node_id
    node_repl, is_new4 = register_or_update_node(
        registry=reg,
        hostname="gpu-01-replaced",
        mac_address="00:99:88:77:66:55",
        ssh_user="ubuntu",
        ssh_host_key="ssh-ed25519 AAAAFINGERPRINT_REPLACED",
        replace_node_id="node-01",
    )
    assert is_new4 is False
    assert node_repl.identity.id == "node-01"
    assert node_repl.identity.mac_address == "00:99:88:77:66:55"


def test_dnsmasq_hosts_generation() -> None:
    reg = NodeRegistry()
    reg.nodes["node-01"] = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="gpu-01",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
        )
    )
    reg.nodes["node-02"] = NodeRecord(
        identity=NodeIdentity(
            id="node-02",
            hostname="gpu-02",
            mac_address="00:aa:bb:cc:dd:ee",
            reserved_ip="10.42.0.3",
        )
    )

    hosts_text = generate_dnsmasq_hosts(reg)
    assert "00:11:22:33:44:55,10.42.0.2,node-01,infinite" in hosts_text
    assert "00:aa:bb:cc:dd:ee,10.42.0.3,node-02,infinite" in hosts_text


def test_known_hosts_sync(tmp_path: Path) -> None:
    reg = NodeRegistry()
    reg.nodes["node-01"] = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="gpu-01",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_host_fingerprint="ssh-ed25519 AAAAKEY1",
        )
    )
    known_hosts = sync_known_hosts(tmp_path, reg)
    assert known_hosts.exists()
    content = known_hosts.read_text()
    assert "10.42.0.2,node-01 ssh-ed25519 AAAAKEY1" in content


def test_healthy_serving_nodes_filtering() -> None:
    reg = NodeRegistry()
    # Ready node
    reg.nodes["node-01"] = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="n1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(status="ready", http_healthy=True, systemd_active=True),
    )
    # Unhealthy node
    reg.nodes["node-02"] = NodeRecord(
        identity=NodeIdentity(
            id="node-02",
            hostname="n2",
            mac_address="00:aa:bb:cc:dd:ee",
            reserved_ip="10.42.0.3",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(status="unhealthy", http_healthy=False, systemd_active=True),
    )
    # Disabled node
    reg.nodes["node-03"] = NodeRecord(
        identity=NodeIdentity(
            id="node-03",
            hostname="n3",
            mac_address="00:ff:ee:dd:cc:bb",
            reserved_ip="10.42.0.4",
        ),
        desired=NodeDesiredConfig(enabled=False),
        runtime=NodeRuntimeState(status="ready", http_healthy=True, systemd_active=True),
    )

    healthy = get_healthy_serving_nodes(reg)
    assert len(healthy) == 1
    assert healthy[0].identity.id == "node-01"


def test_enrollment_server_http_flow(tmp_path: Path) -> None:
    # Setup test secrets and script
    secrets_dir = tmp_path / "secrets"
    secrets_dir.mkdir()
    (secrets_dir / "enrollment_token").write_text("test-session-token-1234")

    ssh_dir = secrets_dir / "ssh"
    ssh_dir.mkdir()
    (ssh_dir / "cluster_orchestrator_key.pub").write_text("ssh-ed25519 CLUSTER_MAC_PUB_KEY")

    scripts_dir = tmp_path / "scripts" / "inference"
    scripts_dir.mkdir(parents=True)
    (scripts_dir / "node-enroll.sh").write_text("#!/bin/bash\necho enroll")

    # Start test enrollment server on ephemeral port on 127.0.0.1
    server = make_enrollment_server(tmp_path, host="127.0.0.1", port=0)
    port = server.server_address[1]

    import threading

    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    try:
        base_url = f"http://127.0.0.1:{port}"

        # 1. Download node-enroll.sh
        with urllib.request.urlopen(f"{base_url}/node-enroll.sh") as resp:
            assert resp.status == 200
            assert b"echo enroll" in resp.read()

        # 2. Reject invalid token
        bad_payload = json.dumps(
            {
                "token": "wrong-token",
                "hostname": "linux-node",
                "mac_address": "00:11:22:33:44:55",
                "ssh_user": "ubuntu",
            }
        ).encode("utf-8")
        req_bad = urllib.request.Request(
            f"{base_url}/api/enroll",
            data=bad_payload,
            headers={"Content-Type": "application/json"},
        )
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(req_bad)
        assert exc_info.value.code == 403

        # 3. Successful enrollment with valid token
        good_payload = json.dumps(
            {
                "token": "test-session-token-1234",
                "hostname": "linux-node-01",
                "mac_address": "00:11:22:33:44:55",
                "ssh_user": "ubuntu",
                "ssh_host_key": "ssh-ed25519 LINUX_HOST_KEY",
                "hardware": {
                    "cpu": "AMD Ryzen",
                    "ram_gb": 64,
                    "gpus": [{"name": "RTX 4090", "vram_gb": 24}],
                },
            }
        ).encode("utf-8")
        req_good = urllib.request.Request(
            f"{base_url}/api/enroll",
            data=good_payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req_good) as resp:
            assert resp.status == 200
            resp_data = json.loads(resp.read().decode("utf-8"))
            assert resp_data["status"] == "ok"
            assert resp_data["node_id"] == "node-01"
            assert resp_data["reserved_ip"] == "10.42.0.2"
            assert resp_data["cluster_public_key"] == "ssh-ed25519 CLUSTER_MAC_PUB_KEY"

        # Verify registry and dnsmasq.hosts files were created on disk
        reg = load_registry(tmp_path)
        assert len(reg.nodes) == 1
        assert "node-01" in reg.nodes
        assert (tmp_path / "state" / "dnsmasq.hosts").exists()
        assert (tmp_path / "state" / "known_hosts").exists()

    finally:
        server.shutdown()
        server.server_close()


def test_node_registry_manager_direct(tmp_path: Path) -> None:
    from ai_platform.nodes import NodeRegistryManager

    manager = NodeRegistryManager(tmp_path)
    # Empty load
    reg = manager.load()
    assert len(reg.nodes) == 0

    # Enroll node
    record, is_new = manager.enroll_node(
        hostname="rig-01",
        mac_address="00:11:22:33:44:55",
        ssh_user="ubuntu",
        ssh_host_key="ssh-ed25519 HOSTKEY1",
        current_ip="10.42.0.150",
    )
    assert is_new is True
    assert record.identity.id == "node-01"
    assert record.identity.reserved_ip == "10.42.0.2"

    # Verify atomic files on disk
    assert (tmp_path / "state" / "nodes.yaml").exists()
    assert (tmp_path / "state" / "dnsmasq.hosts").exists()
    assert (tmp_path / "state" / "known_hosts").exists()

    dnsmasq_content = (tmp_path / "state" / "dnsmasq.hosts").read_text()
    assert "00:11:22:33:44:55,10.42.0.2,node-01,infinite" in dnsmasq_content

    known_hosts_content = (tmp_path / "state" / "known_hosts").read_text()
    assert "10.42.0.2,node-01,10.42.0.150 ssh-ed25519 HOSTKEY1" in known_hosts_content
