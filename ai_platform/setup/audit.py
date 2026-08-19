"""System diagnostic audit functionality for SetupEngine."""

from __future__ import annotations

import os
import shutil
import socket
import time
from pathlib import Path
from typing import Any

from ai_platform.setup.readiness import check_empirical_phase_status


def run_full_audit(project_root: Path) -> dict[str, Any]:
    """Execute comprehensive system diagnostic audit across host, VM, networking, and containers."""
    audit_items: list[dict[str, Any]] = []

    def add_item(
        category: str, name: str, passed: bool, status: str, details: str, fix: str | None = None
    ) -> None:
        audit_items.append(
            {
                "category": category,
                "name": name,
                "passed": passed,
                "status": status,
                "details": details,
                "fix": fix,
            }
        )

    # 1. System & Architecture
    uname = os.uname()
    is_arm64 = uname.machine == "arm64"
    add_item(
        "Host System",
        "Apple Silicon Architecture",
        is_arm64,
        "OPTIMAL" if is_arm64 else "COMPATIBLE",
        f"Darwin {uname.release} ({uname.machine})",
    )

    # 2. Tooling
    for tool_name, cmd in [
        ("Homebrew", ["brew", "--version"]),
        ("Python 3.12+", ["python3", "--version"]),
        ("uv Package Manager", ["uv", "--version"]),
        ("Podman Engine", ["podman", "--version"]),
        ("jq JSON Processor", ["jq", "--version"]),
        ("yq YAML Processor", ["yq", "--version"]),
    ]:
        found = shutil.which(cmd[0]) is not None
        add_item(
            "Tooling",
            tool_name,
            found,
            "INSTALLED" if found else "MISSING",
            "Available in PATH" if found else "Run ./bootstrap.sh to install missing tool",
            fix=f"brew install {cmd[0]}" if not found else None,
        )

    # 3. Podman Machine
    pm_status, pm_details, _ = check_empirical_phase_status("05-podman", project_root)
    add_item(
        "Infrastructure",
        "Podman Linux VM (ai-platform)",
        pm_status == "completed",
        "RUNNING" if pm_status == "completed" else "STOPPED/MISSING",
        "Virtual machine active and accepting OCI commands"
        if pm_status == "completed"
        else "Run Machine Init phase from Setup tab",
        fix="podman machine start ai-platform" if pm_status != "completed" else None,
    )

    # 4. Networking
    net_status, net_details, _ = check_empirical_phase_status("06a-networking", project_root)
    add_item(
        "Networking",
        "Private Subnet IP (10.42.0.1)",
        net_status == "completed",
        "CONFIGURED" if net_status == "completed" else "UNCONFIGURED",
        "Ethernet interface static IP active"
        if net_status == "completed"
        else "Run Networking phase to bind 10.42.0.1",
        fix="sudo bash scripts/install/06a-networking.sh" if net_status != "completed" else None,
    )

    # 5. Remote GPU Nodes (dynamic query)
    nodes_ping_ok = False
    try:
        from ai_platform.nodes import load_registry

        reg = load_registry(project_root)
        if reg.nodes:
            online_cnt = sum(
                1 for n in reg.nodes.values() if n.state in ("serving", "ready", "connected")
            )
            nodes_ping_ok = online_cnt > 0
    except Exception:
        pass

    add_item(
        "Networking",
        "Enrolled Linux Nodes Reachability",
        nodes_ping_ok,
        "REACHABLE" if nodes_ping_ok else "NO_ONLINE_NODES",
        "At least one enrolled node online and responding"
        if nodes_ping_ok
        else "Verify Ethernet cable connected and nodes enrolled",
        fix="Run enrollment script on Linux PC: bash node-enroll.sh",
    )

    # 6. Containers
    dep_status, dep_details, _ = check_empirical_phase_status("09-deploy", project_root)
    running_cnt = len(dep_details.get("matched_services", []))
    add_item(
        "Containers",
        "Control Plane Containers",
        dep_status == "completed",
        f"{running_cnt}/6 ACTIVE",
        "All 6 Podman service containers active"
        if dep_status == "completed"
        else "Run Deploy Services phase from Setup tab",
        fix="podman compose up -d" if dep_status != "completed" else None,
    )

    # 7. Ports
    for name, p in [("Caddy (:8080)", 8080), ("LiteLLM (:4000)", 4000), ("Langfuse (:3000)", 3000)]:
        is_open = False
        try:
            with socket.create_connection(("127.0.0.1", p), timeout=0.2):
                is_open = True
        except Exception:
            pass
        add_item(
            "Health Probes",
            name,
            is_open,
            "LISTENING" if is_open else "CLOSED",
            f"TCP port {p} responsive" if is_open else f"Port {p} not answering",
            fix=f"Check container status: podman logs {name.split()[0].lower()}"
            if not is_open
            else None,
        )

    passed_cnt = sum(1 for i in audit_items if i["passed"])
    total_cnt = len(audit_items)

    return {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "total_checks": total_cnt,
        "passed_checks": passed_cnt,
        "failed_checks": total_cnt - passed_cnt,
        "overall_health": "HEALTHY"
        if passed_cnt == total_cnt
        else ("DEGRADED" if passed_cnt >= total_cnt * 0.7 else "ACTION_REQUIRED"),
        "checks": audit_items,
    }
