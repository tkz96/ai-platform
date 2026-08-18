import socket
import urllib.error
import urllib.request
from pathlib import Path
from platform.config import ResolvedPlatform, ServiceManifest
from platform.nodes import NodeRecord, load_registry
from typing import Any

from rich.console import Group
from rich.table import Table


def check_endpoint(url: str, timeout: int = 5) -> tuple[bool, str]:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "AI-Platform-Verifier/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if 200 <= resp.status < 400:
                return True, f"HTTP {resp.status}"
            return False, f"HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)


def check_tcp_port(host: str, port: int, timeout: int = 5) -> tuple[bool, str]:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, "TCP Connection OK"
    except Exception as e:
        return False, str(e)


def verify_service(service_name: str, manifest: ServiceManifest) -> dict[str, Any]:
    if not manifest.ports:
        return {
            "name": service_name,
            "status": "HEALTHY (No ports exposed)",
            "passed": True,
        }

    host_port = manifest.ports[0].host_port

    if manifest.health and manifest.health.endpoint:
        target_url = f"http://localhost:{host_port}{manifest.health.endpoint}"
        passed, message = check_endpoint(target_url)
        return {
            "name": service_name,
            "endpoint": target_url,
            "status": "HEALTHY" if passed else f"UNHEALTHY ({message})",
            "passed": passed,
        }

    passed, message = check_tcp_port("localhost", host_port)
    return {
        "name": service_name,
        "endpoint": f"tcp://localhost:{host_port}",
        "status": "HEALTHY" if passed else f"UNHEALTHY ({message})",
        "passed": passed,
    }


def verify_node(node: NodeRecord) -> dict[str, Any]:
    ip = node.identity.reserved_ip
    model_assign = node.desired.models[0] if node.desired.models else None
    port = model_assign.port if model_assign else 8080
    health_endpoint = model_assign.health_endpoint if model_assign else "/health"
    proto = model_assign.protocol if model_assign else "http"
    model_name = node.runtime.active_model or (
        model_assign.model_name if model_assign else "Unknown"
    )

    tcp_passed, tcp_msg = check_tcp_port(ip, port)
    health_url = f"{proto}://{ip}:{port}{health_endpoint}"
    http_passed, http_msg = check_endpoint(health_url)

    # Format hardware summary
    hw_str = "CPU Mode"
    if node.runtime.hardware and node.runtime.hardware.gpus:
        gpus = node.runtime.hardware.gpus
        gpu_summary = ", ".join(f"{g.name} ({g.vram_gb}GB)" for g in gpus)
        hw_str = f"{gpu_summary} ({node.runtime.hardware.ram_gb}GB RAM)"
    elif node.runtime.hardware:
        hw_str = f"{node.runtime.hardware.cpu} ({node.runtime.hardware.ram_gb}GB RAM)"

    return {
        "node_id": node.identity.id,
        "ip": ip,
        "hardware": hw_str,
        "active_model": model_name,
        "tcp_passed": tcp_passed,
        "tcp_status": "OPEN" if tcp_passed else f"CLOSED ({tcp_msg})",
        "http_passed": http_passed,
        "http_status": "OK" if http_passed else f"UNHEALTHY ({http_msg})",
        "status": "READY" if (tcp_passed and http_passed) else "UNHEALTHY",
        "passed": tcp_passed and http_passed,
    }


def verify_remote_inference(
    resolved: ResolvedPlatform, root_dir: Path | None = None
) -> list[dict[str, Any]]:
    target_root = root_dir or Path.cwd()
    registry = load_registry(target_root)

    if registry.nodes:
        results: list[dict[str, Any]] = []
        for node in registry.nodes.values():
            results.append(verify_node(node))
        return results

    # Fallback to single-node from platform.yaml if no nodes in registry yet
    inf = resolved.config.inference
    tcp_passed, tcp_msg = check_tcp_port(inf.host, inf.port)
    health_url = f"{inf.protocol}://{inf.host}:{inf.port}{inf.health_endpoint}"
    http_passed, http_msg = check_endpoint(health_url)

    return [
        {
            "node_id": "node-01 (default)",
            "ip": inf.host,
            "hardware": "Configured Inference Node",
            "active_model": resolved.config.default_model,
            "tcp_passed": tcp_passed,
            "tcp_status": "OPEN" if tcp_passed else f"CLOSED ({tcp_msg})",
            "http_passed": http_passed,
            "http_status": "OK" if http_passed else f"UNHEALTHY ({http_msg})",
            "status": "READY" if (tcp_passed and http_passed) else "UNHEALTHY",
            "passed": tcp_passed and http_passed,
        }
    ]


def verify_platform(resolved: ResolvedPlatform, root_dir: Path | None = None) -> dict[str, Any]:
    local_results: list[dict[str, Any]] = []
    for service_name in resolved.dependency_order:
        manifest = resolved.services[service_name]
        local_results.append(verify_service(service_name, manifest))

    remote_results = verify_remote_inference(resolved, root_dir=root_dir)

    return {
        "local_services": local_results,
        "remote_inference": remote_results,
    }


def format_health_table(results: dict[str, Any] | list[dict[str, Any]]) -> Group:
    if isinstance(results, list):
        local_results = results
        remote_results = []
    else:
        local_results = results.get("local_services", [])
        remote_results = results.get("remote_inference", [])

    local_table = Table(title="Local Platform Services (Control Plane)")
    local_table.add_column("Service", style="cyan", no_wrap=True)
    local_table.add_column("Endpoint", style="blue")
    local_table.add_column("Status", style="bold")

    for r in local_results:
        status_style = "green" if r["passed"] else "red"
        local_table.add_row(
            r["name"],
            r.get("endpoint", "N/A"),
            f"[{status_style}]{r['status']}[/{status_style}]",
        )

    remote_table = Table(title="Remote Inference Cluster (10.42.0.0/24)")
    remote_table.add_column("Node ID", style="cyan", no_wrap=True)
    remote_table.add_column("Reserved IP", style="blue")
    remote_table.add_column("Hardware / GPU", style="magenta")
    remote_table.add_column("Active Model", style="yellow")
    remote_table.add_column("TCP (8080)", style="bold")
    remote_table.add_column("HTTP Health", style="bold")

    for r in remote_results:
        tcp_style = "green" if r.get("tcp_passed") else "yellow"
        http_style = "green" if r.get("http_passed") else "yellow"
        remote_table.add_row(
            r.get("node_id", "node-XX"),
            r.get("ip", "10.42.0.X"),
            r.get("hardware", "N/A"),
            r.get("active_model", "N/A"),
            f"[{tcp_style}]{r.get('tcp_status', 'N/A')}[/{tcp_style}]",
            f"[{http_style}]{r.get('http_status', 'N/A')}[/{http_style}]",
        )

    return Group(local_table, remote_table)
