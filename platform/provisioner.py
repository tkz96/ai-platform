from __future__ import annotations

import datetime
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from platform.nodes import (
    GPUInfo,
    HardwareSpecs,
    ModelAssignment,
    NodeRecord,
    NodeRegistry,
    load_registry,
    save_registry,
    sync_known_hosts,
)


class SSHRunner:
    def __init__(self, root_dir: Path, timeout: int = 10) -> None:
        self.root_dir = root_dir
        self.key_file = root_dir / "secrets" / "ssh" / "cluster_orchestrator_key"
        self.known_hosts = root_dir / "state" / "known_hosts"
        self.timeout = timeout

    def run_cmd(
        self,
        host: str,
        user: str,
        command: str,
        port: int = 22,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        """Execute a remote command over SSH with strict host key verification."""
        ssh_cmd = [
            "ssh",
            "-i",
            str(self.key_file),
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={self.known_hosts}",
            "-o",
            f"ConnectTimeout={self.timeout}",
            "-p",
            str(port),
            f"{user}@{host}",
            command,
        ]
        return subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            check=check,
            timeout=self.timeout + 15,
        )

    def scp_file(
        self,
        local_file: Path,
        remote_dest: str,
        host: str,
        user: str,
        port: int = 22,
    ) -> None:
        """Copy a file to remote host using scp."""
        scp_cmd = [
            "scp",
            "-i",
            str(self.key_file),
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={self.known_hosts}",
            "-o",
            f"ConnectTimeout={self.timeout}",
            "-P",
            str(port),
            str(local_file),
            f"{user}@{host}:{remote_dest}",
        ]
        subprocess.run(scp_cmd, capture_output=True, text=True, check=True, timeout=30)


def render_systemd_unit(node: NodeRecord, model: ModelAssignment) -> str:
    """Generate systemd service content for llama-server."""
    user = node.identity.ssh_user
    workdir = f"/home/{user}" if user != "root" else "/root"
    extra_flags = " ".join(model.extra_args)

    content = f"""[Unit]
Description=AI Platform llama.cpp Inference Server ({node.identity.id})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User={user}
WorkingDirectory={workdir}
ExecStart={model.model_path and '/usr/local/bin/llama-server' or '/usr/local/bin/llama-server'} \\
    --host {node.identity.reserved_ip} \\
    --port {model.port} \\
    --model {model.model_path} \\
    {extra_flags}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""
    return content


def probe_remote_health(
    ip: str, port: int, endpoint: str = "/health", timeout: int = 4
) -> tuple[bool, dict[str, Any] | None, float]:
    """Probe HTTP health endpoint on inference node and record response body."""
    url = f"http://{ip}:{port}{endpoint}"
    start_time = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "AI-Platform-Provisioner/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            latency_ms = (time.time() - start_time) * 1000
            if 200 <= resp.status < 400:
                body = resp.read().decode("utf-8")
                try:
                    data = json.loads(body)
                    return True, data, latency_ms
                except Exception:
                    return True, {"raw": body}, latency_ms
            return False, None, latency_ms
    except Exception:
        latency_ms = (time.time() - start_time) * 1000
        return False, None, latency_ms


def check_tcp_port(ip: str, port: int, timeout: int = 3) -> bool:
    """Check TCP connectivity to target IP and port."""
    import socket

    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def provision_single_node(root_dir: Path, node: NodeRecord) -> dict[str, Any]:
    """Remotely provision a single Linux inference node over SSH with strict verification."""
    ssh = SSHRunner(root_dir)
    target_ip = node.identity.reserved_ip
    user = node.identity.ssh_user
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    results: dict[str, Any] = {
        "node_id": node.identity.id,
        "ip": target_ip,
        "success": False,
        "steps": {},
    }

    try:
        # Step 1: Check SSH reachability
        node.runtime.status = "provisioning"
        res = ssh.run_cmd(target_ip, user, "uname -a", check=False)
        if res.returncode != 0:
            # Fallback to current_ip if node has not acquired reserved IP yet
            if node.runtime.current_ip and node.runtime.current_ip != target_ip:
                target_ip = node.runtime.current_ip
                res = ssh.run_cmd(target_ip, user, "uname -a", check=False)

        if res.returncode != 0:
            node.runtime.status = "offline"
            node.runtime.last_error = f"SSH unreachable at {target_ip}: {res.stderr.strip()}"
            results["steps"]["ssh"] = "failed"
            return results

        results["steps"]["ssh"] = "ok"

        # Step 2: Hardware inspection
        hw_cmd = "lscpu | grep 'Model name' || true; free -b | grep Mem || true; command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits || true"
        hw_res = ssh.run_cmd(target_ip, user, hw_cmd, check=False)
        results["steps"]["hardware_inspection"] = "ok"

        # Step 3: Render and upload systemd unit
        model = (
            node.desired.models[0] if node.desired.models else ModelAssignment()
        )
        service_content = render_systemd_unit(node, model)

        tmp_service_file = root_dir / "state" / f"llama-server-{node.identity.id}.service"
        tmp_service_file.write_text(service_content)

        remote_tmp = f"/tmp/llama-server-{node.identity.id}.service"
        ssh.scp_file(tmp_service_file, remote_tmp, target_ip, user)

        # Install unit file with sudo
        install_cmd = f"sudo cp {remote_tmp} /etc/systemd/system/llama-server.service && sudo chmod 644 /etc/systemd/system/llama-server.service && sudo systemctl daemon-reload && sudo systemctl enable llama-server.service"
        ssh.run_cmd(target_ip, user, install_cmd, check=True)
        results["steps"]["systemd_unit"] = "installed"

        # Step 4: Verify prerequisites & model presence
        bin_check = ssh.run_cmd(
            target_ip,
            user,
            "test -x /usr/local/bin/llama-server || command -v llama-server",
            check=False,
        )
        model_check = ssh.run_cmd(
            target_ip,
            user,
            f"test -f '{model.model_path}'",
            check=False,
        )

        bin_ok = bin_check.returncode == 0
        model_ok = model_check.returncode == 0

        if bin_ok and model_ok:
            ssh.run_cmd(
                target_ip,
                user,
                "sudo systemctl restart llama-server.service",
                check=False,
            )
            results["steps"]["service_start"] = "restarted"
            time.sleep(2)
        else:
            missing_items = []
            if not bin_ok:
                missing_items.append("llama-server binary")
            if not model_ok:
                missing_items.append(f"model file ({model.model_path})")
            node.runtime.status = "model_missing"
            node.runtime.last_error = f"Prerequisites missing: {', '.join(missing_items)}"
            results["steps"]["service_start"] = "pending_prerequisites"
            results["success"] = True
            return results

        # Step 5: Verify Evidence-Based Service Readiness
        # 1. Systemd active
        status_res = ssh.run_cmd(
            target_ip,
            user,
            "systemctl is-active llama-server.service",
            check=False,
        )
        systemd_active = status_res.stdout.strip() == "active"
        node.runtime.systemd_active = systemd_active

        # 2. TCP Port listening
        tcp_open = check_tcp_port(target_ip, model.port, timeout=3)
        node.runtime.tcp_open = tcp_open

        # 3. HTTP Health & Model Confirmation
        http_ok, health_data, latency_ms = probe_remote_health(
            target_ip, model.port, model.health_endpoint, timeout=4
        )
        node.runtime.http_healthy = http_ok
        node.runtime.latency_ms = latency_ms

        if systemd_active and tcp_open and http_ok:
            node.runtime.status = "ready"
            node.runtime.active_model = model.model_name
            node.runtime.last_seen = now_iso
            node.runtime.last_error = None
            results["success"] = True
        else:
            node.runtime.status = "unhealthy"
            node.runtime.last_error = f"Health check failed (systemd={systemd_active}, tcp={tcp_open}, http={http_ok})"
            results["success"] = False

        results["steps"]["health_verification"] = {
            "systemd": systemd_active,
            "tcp": tcp_open,
            "http": http_ok,
            "latency_ms": latency_ms,
        }

    except Exception as e:
        node.runtime.status = "unhealthy"
        node.runtime.last_error = str(e)
        results["error"] = str(e)
        results["success"] = False

    return results


def provision_all_nodes(root_dir: Path) -> dict[str, Any]:
    """Provision all enrolled nodes in state/nodes.yaml with per-node fault isolation."""
    registry = load_registry(root_dir)
    sync_known_hosts(root_dir, registry)

    results: dict[str, Any] = {}
    for node_id, node in registry.nodes.items():
        if not node.desired.enabled:
            continue
        res = provision_single_node(root_dir, node)
        results[node_id] = res

    save_registry(root_dir, registry)
    return results
