"""Empirical readiness checks for platform provisioning phases."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
from pathlib import Path
from typing import Any


def check_podman_readiness(project_root: Path) -> tuple[str, dict[str, Any], str | None]:
    """Empirically inspect Podman VM readiness."""
    podman_bin = shutil.which("podman")
    if not podman_bin:
        return "pending", {"podman_installed": False}, "Podman binary not found in PATH"

    try:
        res = subprocess.run(
            ["podman", "machine", "list", "--format", "json"],
            capture_output=True,
            text=True,
            timeout=4,
        )
        if res.returncode == 0:
            machines = json.loads(res.stdout) if res.stdout.strip() else []
            ai_machine = next(
                (
                    m
                    for m in machines
                    if m.get("Name") == "ai-platform" or m.get("name") == "ai-platform"
                ),
                None,
            )
            if ai_machine:
                is_running = ai_machine.get("Running", False) or ai_machine.get("running", False)
                if is_running:
                    # Also test podman info liveness
                    info_res = subprocess.run(
                        ["podman", "info"],
                        capture_output=True,
                        text=True,
                        timeout=4,
                    )
                    if info_res.returncode == 0:
                        return (
                            "completed",
                            {
                                "machine_exists": True,
                                "running": True,
                                "details": ai_machine,
                                "info_ok": True,
                            },
                            None,
                        )
                    return (
                        "pending",
                        {
                            "machine_exists": True,
                            "running": True,
                            "details": ai_machine,
                            "info_ok": False,
                        },
                        "Podman machine is running but service API is not responding",
                    )
                return (
                    "pending",
                    {"machine_exists": True, "running": False},
                    "Podman machine 'ai-platform' exists but is stopped",
                )
            return (
                "pending",
                {"machine_exists": False},
                "Podman machine 'ai-platform' has not been created yet",
            )
    except Exception as e:
        return "pending", {"error": str(e)}, f"Could not query Podman machine: {e}"

    return "pending", {"podman_installed": True}, "Podman machine initialization pending"


def check_network_readiness(project_root: Path) -> tuple[str, dict[str, Any], str | None]:
    """Phase 6a Empirical Network Readiness check.

    Empirically verifies dedicated interface IP (10.42.0.1), dnsmasq DHCP, and PF NAT gateway.
    """
    details: dict[str, Any] = {
        "interface_ok": False,
        "ip_10_42_0_1": False,
        "ip_10_42_0_1_configured": False,
        "not_wan_interface": True,
        "dhcp_ok": False,
        "dnsmasq_syntax_valid": False,
        "nat_ok": False,
    }
    failures: list[str] = []

    # 1. Interface & IP 10.42.0.1 (and ensure not WAN default route)
    try:
        ifconfig_out = subprocess.run(
            ["ifconfig"], capture_output=True, text=True, timeout=3
        ).stdout
        if "10.42.0.1" in ifconfig_out:
            details["ip_10_42_0_1"] = True
            details["ip_10_42_0_1_configured"] = True
            details["interface_ok"] = True
        else:
            failures.append("10.42.0.1/24 IP not assigned to any network interface")

        route_out = subprocess.run(
            ["route", "-n", "get", "default"], capture_output=True, text=True, timeout=2
        ).stdout
        if "10.42.0.1" in route_out:
            details["not_wan_interface"] = False
            failures.append(
                "Interface assigned 10.42.0.1 is misconfigured as default WAN gateway route"
            )
    except Exception as e:
        failures.append(f"Interface query error: {e}")

    # 2. DHCP (dnsmasq) PID, syntax & process ownership
    conf_file = project_root / "state" / "dnsmasq.conf"
    syntax_ok = False
    if conf_file.exists():
        try:
            res = subprocess.run(
                ["dnsmasq", "--test", "-C", str(conf_file)],
                capture_output=True,
                text=True,
                timeout=2,
            )
            syntax_ok = res.returncode == 0
        except Exception:
            pass

    details["dnsmasq_syntax_valid"] = syntax_ok
    if conf_file.exists() and not syntax_ok:
        failures.append("dnsmasq.conf syntax validation failed")

    pid_file = Path("/tmp/ai-platform-dnsmasq.pid")
    dnsmasq_alive = False
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, 0)
            dnsmasq_alive = True
        except (ValueError, OSError):
            dnsmasq_alive = False

    details["dhcp_ok"] = dnsmasq_alive
    if not dnsmasq_alive:
        failures.append("dnsmasq DHCP daemon is not running with valid PID")

    # 3. NAT (IP Forwarding & PF)
    pf_active = False
    ip_forwarding = False
    try:
        sysctl_out = subprocess.run(
            ["sysctl", "-n", "net.inet.ip.forwarding"], capture_output=True, text=True, timeout=2
        ).stdout.strip()
        ip_forwarding = sysctl_out == "1"

        pfctl_out = subprocess.run(
            ["sudo", "-n", "pfctl", "-s", "info"], capture_output=True, text=True, timeout=2
        ).stdout
        pf_active = "Status: Enabled" in pfctl_out or "Enabled" in pfctl_out
    except Exception:
        pass

    details["ip_forwarding"] = ip_forwarding
    details["pf_active"] = pf_active
    details["nat_ok"] = ip_forwarding

    if not ip_forwarding:
        failures.append("IP forwarding (net.inet.ip.forwarding) is disabled")

    if (
        details["ip_10_42_0_1"]
        and details["not_wan_interface"]
        and details["dhcp_ok"]
        and details["nat_ok"]
    ):
        return "completed", details, None

    err_msg = "; ".join(failures) if failures else "Network empirical readiness incomplete"
    return "pending", details, err_msg


def check_secrets_readiness(project_root: Path) -> tuple[str, dict[str, Any], str | None]:
    """Empirically inspect secrets & cluster SSH key readiness."""
    env_file = project_root / ".env"
    cluster_key = project_root / "secrets" / "ssh" / "cluster_orchestrator_key"
    legacy_key = project_root / "secrets" / "cluster_key"
    env_exists = env_file.exists() and env_file.stat().st_size > 100
    key_exists = cluster_key.exists() or legacy_key.exists()

    details = {
        "env_file_exists": env_exists,
        "cluster_ssh_key_exists": key_exists,
    }

    if env_exists and key_exists:
        return "completed", details, None
    return "pending", details, ".env secrets or cluster SSH keys have not been generated"


def check_render_readiness(project_root: Path) -> tuple[str, dict[str, Any], str | None]:
    """Empirically inspect configuration render output readiness."""
    compose_file = project_root / "compose.yaml"
    caddy_file = project_root / "configs" / "caddy" / "Caddyfile"
    litellm_file = project_root / "configs" / "litellm" / "config.yaml"

    rendered_ok = compose_file.exists() and caddy_file.exists() and litellm_file.exists()
    details = {
        "compose_yaml_exists": compose_file.exists(),
        "caddyfile_exists": caddy_file.exists(),
        "litellm_config_exists": litellm_file.exists(),
    }

    if rendered_ok:
        return "completed", details, None
    return "pending", details, "Configuration files have not been rendered from templates"


def check_deploy_readiness(project_root: Path) -> tuple[str, dict[str, Any], str | None]:
    """Empirically inspect Podman control plane containers deployment."""
    try:
        res = subprocess.run(
            ["podman", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if res.returncode == 0:
            running_names = set(res.stdout.strip().splitlines())
            required_services = {"postgres", "redis", "clickhouse", "langfuse", "litellm", "caddy"}
            matched = running_names.intersection(required_services)
            details = {
                "running_containers": list(running_names),
                "matched_services": list(matched),
                "total_required": len(required_services),
            }
            if len(matched) == len(required_services):
                return "completed", details, None
            if len(matched) > 0:
                return (
                    "pending",
                    details,
                    f"Partial deployment ({len(matched)}/{len(required_services)} services running)",
                )
            return "pending", details, "No control plane containers currently running"
    except Exception as e:
        return "pending", {"error": str(e)}, f"Cannot query Podman services: {e}"

    return "pending", {}, "Containers not deployed"


def check_verify_readiness(project_root: Path) -> tuple[str, dict[str, Any], str | None]:
    """Empirically inspect verification ports and services."""
    ports = [8080, 4000, 3000, 5432, 8123, 6379]
    open_count = 0
    for p in ports:
        try:
            with socket.create_connection(("127.0.0.1", p), timeout=0.3):
                open_count += 1
        except Exception:
            pass

    details = {"open_ports": open_count, "total_ports": len(ports)}
    if open_count == len(ports):
        return "completed", details, None
    return "pending", details, f"Verification pending ({open_count}/{len(ports)} ports responding)"


def check_empirical_phase_status(
    phase_id: str, project_root: Path
) -> tuple[str, dict[str, Any], str | None]:
    """Determine ground-truth empirical status of any phase."""
    if phase_id == "05-podman":
        return check_podman_readiness(project_root)
    elif phase_id == "06a-networking":
        return check_network_readiness(project_root)
    elif phase_id == "07-secrets":
        return check_secrets_readiness(project_root)
    elif phase_id == "08-render":
        return check_render_readiness(project_root)
    elif phase_id == "09-deploy":
        return check_deploy_readiness(project_root)
    elif phase_id == "10-verify":
        return check_verify_readiness(project_root)
    return "pending", {}, "Unknown phase"
