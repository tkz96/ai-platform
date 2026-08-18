from __future__ import annotations

import datetime
import subprocess
import time
from pathlib import Path
from platform.config import ResolvedPlatform, resolve_platform
from platform.nodes import (
    ModelAssignment,
    NodeRecord,
    load_registry,
    save_registry,
    sync_known_hosts,
)
from platform.probe import probe_http, probe_tcp
from platform.renderer import render_node_service_unit
from typing import Any


class SSHRunner:
    def __init__(self, root_dir: Path, timeout: int = 5) -> None:
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
        """Execute a remote command over SSH with strict host key verification and fast timeouts."""
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
            timeout=self.timeout + 3,
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
        subprocess.run(scp_cmd, capture_output=True, text=True, check=True, timeout=10)


def probe_remote_health(
    ip: str, port: int, endpoint: str = "/health", timeout: int = 3
) -> tuple[bool, dict[str, Any] | None, float]:
    """Probe HTTP health endpoint on inference node and record response body."""
    url = f"http://{ip}:{port}{endpoint}"
    res = probe_http(url, timeout=timeout, require_json_status_ok=True)
    return res.passed, res.payload, res.latency_ms


def check_tcp_port(ip: str, port: int, timeout: int = 3) -> bool:
    """Check TCP connectivity to target IP and port using platform.probe."""
    res = probe_tcp(ip, port, timeout=timeout)
    return res.passed


def provision_single_node(
    root_dir: Path,
    node: NodeRecord,
    resolved: ResolvedPlatform | None = None,
) -> dict[str, Any]:
    """Remotely provision a single Linux inference node over SSH with strict verification."""
    if resolved is None:
        resolved = resolve_platform(root_dir)

    ssh = SSHRunner(root_dir, timeout=5)
    target_ip = node.identity.reserved_ip
    user = node.identity.ssh_user
    now_iso = datetime.datetime.now(datetime.UTC).isoformat()

    service_user = node.identity.ssh_user or resolved.config.inference.service_user
    working_dir = resolved.config.inference.working_directory
    binary_path = resolved.config.inference.binary_path
    model = node.desired.models[0] if node.desired.models else ModelAssignment()
    model_path = model.model_path

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
        if res.returncode != 0 and node.runtime.current_ip and node.runtime.current_ip != target_ip:
            # Fallback to current_ip if node has not acquired reserved IP yet
            target_ip = node.runtime.current_ip
            res = ssh.run_cmd(target_ip, user, "uname -a", check=False)

        if res.returncode != 0:
            node.runtime.status = "offline"
            node.runtime.last_error = f"SSH unreachable at {target_ip}: {res.stderr.strip() or 'Connection timeout'}"
            results["steps"]["ssh"] = "failed"
            return results

        results["steps"]["ssh"] = "ok"

        # Step 2: Hardware inspection
        hw_cmd = (
            "lscpu | grep 'Model name' || true; "
            "free -b | grep Mem || true; "
            "command -v nvidia-smi >/dev/null && "
            "nvidia-smi --query-gpu=name,memory.total,driver_version "
            "--format=csv,noheader,nounits || true"
        )
        ssh.run_cmd(target_ip, user, hw_cmd, check=False)
        results["steps"]["hardware_inspection"] = "ok"

        # Step 3: Verify Prerequisites (Binary, Service User, Working Directory, Permissions)
        binary_check = ssh.run_cmd(target_ip, user, f"test -x '{binary_path}'", check=False)
        user_check = ssh.run_cmd(target_ip, user, f"id '{service_user}'", check=False)
        dir_check = ssh.run_cmd(
            target_ip, user, f"sudo -u '{service_user}' test -d '{working_dir}'", check=False
        )
        bin_perm_check = ssh.run_cmd(
            target_ip, user, f"sudo -u '{service_user}' test -x '{binary_path}'", check=False
        )

        prereq_errors: list[str] = []
        if binary_check.returncode != 0:
            prereq_errors.append(f"binary not executable or missing at {binary_path}")
        if user_check.returncode != 0:
            prereq_errors.append(f"service user '{service_user}' does not exist")
        if dir_check.returncode != 0:
            prereq_errors.append(
                f"working directory '{working_dir}' inaccessible by '{service_user}'"
            )
        if bin_perm_check.returncode != 0 and binary_check.returncode == 0:
            prereq_errors.append(f"binary '{binary_path}' not executable by '{service_user}'")

        if prereq_errors:
            node.runtime.status = "prerequisites_missing"
            node.runtime.last_error = f"Prerequisites missing: {', '.join(prereq_errors)}"
            results["steps"]["prerequisites"] = "failed"
            results["steps"]["service_start"] = "prerequisites_missing"
            results["success"] = False
            return results

        results["steps"]["prerequisites"] = "ok"

        # Step 4: Verify Model Presence & Readability
        model_exists = ssh.run_cmd(target_ip, user, f"test -f '{model_path}'", check=False)
        model_readable = ssh.run_cmd(
            target_ip, user, f"sudo -u '{service_user}' test -r '{model_path}'", check=False
        )

        model_errors: list[str] = []
        if model_exists.returncode != 0:
            model_errors.append(f"model file missing at {model_path}")
        elif model_readable.returncode != 0:
            model_errors.append(f"model file at {model_path} not readable by '{service_user}'")

        if model_errors:
            node.runtime.status = "model_missing"
            node.runtime.last_error = f"Model missing: {', '.join(model_errors)}"
            results["steps"]["model"] = "failed"
            results["steps"]["service_start"] = "model_missing"
            results["success"] = False
            return results

        results["steps"]["model"] = "ok"

        # Step 5: Render and upload systemd unit via Jinja2 template
        service_content = render_node_service_unit(root_dir, resolved, node)

        tmp_service_file = root_dir / "state" / f"llama-server-{node.identity.id}.service"
        tmp_service_file.write_text(service_content)

        remote_tmp = f"/tmp/llama-server-{node.identity.id}.service"
        ssh.scp_file(tmp_service_file, remote_tmp, target_ip, user)

        # Install unit file with sudo
        install_cmd = (
            f"sudo cp {remote_tmp} /etc/systemd/system/llama-server.service && "
            f"sudo chmod 644 /etc/systemd/system/llama-server.service && "
            f"sudo systemctl daemon-reload && "
            f"sudo systemctl enable llama-server.service"
        )
        ssh.run_cmd(target_ip, user, install_cmd, check=True)
        results["steps"]["systemd_unit"] = "installed"

        # Step 6: Restart service
        ssh.run_cmd(
            target_ip,
            user,
            "sudo systemctl restart llama-server.service",
            check=False,
        )
        results["steps"]["service_start"] = "restarted"
        time.sleep(2)

        # Step 7: Verify Evidence-Based Service Readiness
        status_res = ssh.run_cmd(
            target_ip,
            user,
            "systemctl is-active llama-server.service",
            check=False,
        )
        systemd_active = status_res.stdout.strip() == "active"
        node.runtime.systemd_active = systemd_active

        tcp_open = check_tcp_port(target_ip, model.port, timeout=3)
        node.runtime.tcp_open = tcp_open

        http_ok, health_data, latency_ms = probe_remote_health(
            target_ip, model.port, model.health_endpoint, timeout=3
        )
        node.runtime.http_healthy = http_ok
        node.runtime.health_response = health_data
        node.runtime.latency_ms = latency_ms

        if systemd_active and tcp_open and http_ok:
            node.runtime.status = "ready"
            node.runtime.active_model = model.model_name
            node.runtime.last_seen = now_iso
            node.runtime.last_error = None
            results["success"] = True
        else:
            node.runtime.status = "unhealthy"
            err_msg = (
                f"Health check failed (systemd={systemd_active}, tcp={tcp_open}, "
                f"http={http_ok}, payload={health_data})"
            )
            node.runtime.last_error = err_msg
            results["success"] = False

        results["steps"]["health_verification"] = {
            "systemd": systemd_active,
            "tcp": tcp_open,
            "http": http_ok,
            "latency_ms": latency_ms,
        }

    except Exception as e:
        node.runtime.status = "offline"
        node.runtime.last_error = str(e)
        results["error"] = str(e)
        results["success"] = False

    return results


def provision_all_nodes(root_dir: Path) -> dict[str, Any]:
    """Provision all enrolled nodes in state/nodes.yaml with per-node fault isolation."""
    registry = load_registry(root_dir)
    sync_known_hosts(root_dir, registry)
    resolved = resolve_platform(root_dir)

    results: dict[str, Any] = {}
    for node_id, node in registry.nodes.items():
        if not node.desired.enabled:
            continue
        if node.runtime.status == "enrolled_pending_ip":
            results[node_id] = {
                "node_id": node_id,
                "ip": node.identity.reserved_ip,
                "success": False,
                "skipped": True,
                "reason": "enrolled_pending_ip: node has not yet acquired reserved IP",
            }
            continue

        try:
            res = provision_single_node(root_dir, node, resolved)
            results[node_id] = res
        except Exception as e:
            node.runtime.status = "offline"
            node.runtime.last_error = f"Unhandled provisioning error: {e}"
            results[node_id] = {
                "node_id": node_id,
                "ip": node.identity.reserved_ip,
                "success": False,
                "error": str(e),
            }
        finally:
            save_registry(root_dir, registry)

    return results
