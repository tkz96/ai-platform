from __future__ import annotations

import datetime
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, Field


class NodeIdentity(BaseModel):
    id: str  # e.g., "node-01"
    hostname: str
    mac_address: str  # canonical lowercase format, e.g. "00:11:22:33:44:55"
    reserved_ip: str  # e.g., "10.42.0.2"
    ssh_user: str = "ubuntu"
    ssh_port: int = 22
    ssh_host_fingerprint: str = ""  # e.g. "ssh-ed25519 AAAAC3..."


class GPUInfo(BaseModel):
    name: str
    vram_gb: int
    count: int = 1
    driver_version: str | None = None
    cuda_version: str | None = None


class HardwareSpecs(BaseModel):
    cpu: str
    ram_gb: int
    gpus: list[GPUInfo] = Field(default_factory=list)


class ModelAssignment(BaseModel):
    """Per-node model serving configuration. Data model supports future multi-model extension."""

    model_name: str = "qwen3.6-35b-a3b"
    model_path: str = "/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf"
    port: int = 8080
    health_endpoint: str = "/health"
    protocol: Literal["http", "https"] = "http"
    extra_args: list[str] = Field(
        default_factory=lambda: [
            "--fit",
            "on",
            "-fa",
            "on",
            "-ctk",
            "q4_0",
            "-ctv",
            "q4_0",
            "-c",
            "32768",
            "-t",
            "14",
            "-cnv",
        ]
    )


class NodeDesiredConfig(BaseModel):
    models: list[ModelAssignment] = Field(default_factory=lambda: [ModelAssignment()])
    enabled: bool = True


NodeStatus = Literal[
    "discovered",
    "enrolled",
    "provisioning",
    "ready",
    "model_missing",
    "unhealthy",
    "offline",
]


class NodeRuntimeState(BaseModel):
    current_ip: str | None = None
    lease_status: str = "reserved"
    status: NodeStatus = "enrolled"
    hardware: HardwareSpecs | None = None
    systemd_active: bool = False
    tcp_open: bool = False
    http_healthy: bool = False
    active_model: str | None = None
    latency_ms: float | None = None
    last_seen: str | None = None
    last_error: str | None = None


class NodeRecord(BaseModel):
    identity: NodeIdentity
    desired: NodeDesiredConfig = Field(default_factory=NodeDesiredConfig)
    runtime: NodeRuntimeState = Field(default_factory=NodeRuntimeState)


class NodeRegistry(BaseModel):
    version: str = "1.0.0"
    mac_ip: str = "10.42.0.1"
    subnet: str = "10.42.0.0/24"
    pool_start: str = "10.42.0.2"
    pool_size: int = 8
    nodes: dict[str, NodeRecord] = Field(default_factory=dict)


def normalize_mac(mac: str) -> str:
    """Normalize MAC address to lowercase colon-separated format."""
    cleaned = mac.strip().lower().replace("-", ":")
    return cleaned


def load_registry(root_dir: Path) -> NodeRegistry:
    """Load registry from state/nodes.yaml, returning empty registry if missing."""
    registry_file = root_dir / "state" / "nodes.yaml"
    if not registry_file.exists():
        return NodeRegistry()
    try:
        raw = yaml.safe_load(registry_file.read_text()) or {}
        return NodeRegistry.model_validate(raw)
    except Exception:
        return NodeRegistry()


def save_registry(root_dir: Path, registry: NodeRegistry) -> Path:
    """Atomically save registry to state/nodes.yaml."""
    state_dir = root_dir / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    registry_file = state_dir / "nodes.yaml"
    tmp_file = state_dir / "nodes.yaml.tmp"

    data = registry.model_dump(mode="json")
    yaml_content = yaml.dump(data, sort_keys=False, indent=2)
    tmp_file.write_text(yaml_content)
    tmp_file.replace(registry_file)
    return registry_file


def allocate_next_node_ip(registry: NodeRegistry) -> tuple[str, str]:
    """Allocate the next available node ID (e.g. node-01) and IP (e.g. 10.42.0.2).

    Pool starts at pool_start (e.g. 10.42.0.2) and has pool_size slots (e.g. 8).
    """
    # Parse base IP prefix and start index
    parts = registry.pool_start.split(".")
    base_prefix = ".".join(parts[:3])
    start_octet = int(parts[3])

    assigned_ips = {n.identity.reserved_ip for n in registry.nodes.values()}
    assigned_ids = set(registry.nodes.keys())

    for idx in range(1, registry.pool_size + 1):
        node_id = f"node-{idx:02d}"
        ip = f"{base_prefix}.{start_octet + idx - 1}"
        if node_id not in assigned_ids and ip not in assigned_ips:
            return node_id, ip

    # If all slots filled, overflow sequentially
    overflow_idx = len(registry.nodes) + 1
    node_id = f"node-{overflow_idx:02d}"
    ip = f"{base_prefix}.{start_octet + overflow_idx - 1}"
    return node_id, ip


def register_or_update_node(
    registry: NodeRegistry,
    hostname: str,
    mac_address: str,
    ssh_user: str,
    ssh_host_key: str,
    current_ip: str | None = None,
    hardware: HardwareSpecs | None = None,
    replace_node_id: str | None = None,
) -> tuple[NodeRecord, bool]:
    """Register a newly enrolled node or idempotently update an existing one.

    Re-enrollment rules:
    - Same MAC + same node ID: Idempotent update
    - New MAC + explicit replace_node_id: Replaces MAC on existing node ID
    - New MAC + no replacement requested: Allocates new node ID and reserved IP
    """
    clean_mac = normalize_mac(mac_address)
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    # Case 1: Check if MAC already exists in registry
    for existing_id, existing_node in registry.nodes.items():
        if normalize_mac(existing_node.identity.mac_address) == clean_mac:
            # Idempotent re-enrollment
            existing_node.identity.hostname = hostname
            existing_node.identity.ssh_user = ssh_user
            if ssh_host_key:
                existing_node.identity.ssh_host_fingerprint = ssh_host_key
            if hardware:
                existing_node.runtime.hardware = hardware
            if current_ip:
                existing_node.runtime.current_ip = current_ip
            existing_node.runtime.last_seen = now_iso
            return existing_node, False

    # Case 2: Explicit replacement of an existing node ID
    if replace_node_id and replace_node_id in registry.nodes:
        node = registry.nodes[replace_node_id]
        node.identity.mac_address = clean_mac
        node.identity.hostname = hostname
        node.identity.ssh_user = ssh_user
        if ssh_host_key:
            node.identity.ssh_host_fingerprint = ssh_host_key
        if hardware:
            node.runtime.hardware = hardware
        if current_ip:
            node.runtime.current_ip = current_ip
        node.runtime.last_seen = now_iso
        return node, False

    # Case 3: Allocate new node ID and reserved IP
    node_id, reserved_ip = allocate_next_node_ip(registry)
    identity = NodeIdentity(
        id=node_id,
        hostname=hostname,
        mac_address=clean_mac,
        reserved_ip=reserved_ip,
        ssh_user=ssh_user,
        ssh_host_fingerprint=ssh_host_key,
    )
    desired = NodeDesiredConfig()
    runtime = NodeRuntimeState(
        current_ip=current_ip or reserved_ip,
        status="enrolled",
        hardware=hardware,
        last_seen=now_iso,
    )
    record = NodeRecord(identity=identity, desired=desired, runtime=runtime)
    registry.nodes[node_id] = record
    return record, True


def generate_dnsmasq_hosts(registry: NodeRegistry) -> str:
    """Generate dnsmasq static lease reservations for state/dnsmasq.hosts.

    Format: <mac_address>,<ip>,<hostname>,infinite
    """
    lines: list[str] = [
        "# AI Platform DHCP Static Lease Reservations",
        "# Auto-generated from state/nodes.yaml — DO NOT EDIT MANUALLY",
    ]
    for node in registry.nodes.values():
        lines.append(
            f"{node.identity.mac_address},{node.identity.reserved_ip},{node.identity.id},infinite"
        )
    return "\n".join(lines) + "\n"


def sync_known_hosts(root_dir: Path, registry: NodeRegistry) -> Path:
    """Synchronize node SSH host keys into state/known_hosts for strict verification."""
    state_dir = root_dir / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    known_hosts_file = state_dir / "known_hosts"

    lines: list[str] = []
    for node in registry.nodes.values():
        fp = node.identity.ssh_host_fingerprint.strip()
        if not fp:
            continue
        # Add entries for both reserved IP and hostname/ID
        ip = node.identity.reserved_ip
        current_ip = node.runtime.current_ip
        node_id = node.identity.id

        hosts = [ip, node_id]
        if current_ip and current_ip != ip:
            hosts.append(current_ip)

        hosts_str = ",".join(hosts)
        lines.append(f"{hosts_str} {fp}")

    content = "\n".join(lines) + ("\n" if lines else "")
    known_hosts_file.write_text(content)
    known_hosts_file.chmod(0o600)
    return known_hosts_file


def get_healthy_serving_nodes(registry: NodeRegistry) -> list[NodeRecord]:
    """Filter registry for nodes eligible to receive traffic in LiteLLM."""
    healthy: list[NodeRecord] = []
    for node in registry.nodes.values():
        if (
            node.desired.enabled
            and node.runtime.status == "ready"
            and node.runtime.http_healthy
            and node.runtime.systemd_active
        ):
            healthy.append(node)
    return healthy
