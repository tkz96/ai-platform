from pathlib import Path
from typing import Any

from rich.console import Group
from rich.table import Table

from ai_platform.config import ResolvedPlatform, ServiceManifest
from ai_platform.nodes import NodeRecord, load_registry
from ai_platform.probe import probe_http, probe_inference_node, probe_tcp


def check_endpoint(url: str, timeout: int = 5) -> tuple[bool, str]:
    """Compatibility wrapper around probe_http."""
    res = probe_http(url, timeout=timeout)
    return res.passed, res.status


def check_tcp_port(host: str, port: int, timeout: int = 5) -> tuple[bool, str]:
    """Compatibility wrapper around probe_tcp."""
    res = probe_tcp(host, port, timeout=timeout)
    return res.passed, res.status


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
        probe_res = probe_http(target_url)
        return {
            "name": service_name,
            "endpoint": target_url,
            "status": "HEALTHY" if probe_res.passed else f"UNHEALTHY ({probe_res.status})",
            "passed": probe_res.passed,
        }

    probe_res = probe_tcp("localhost", host_port)
    return {
        "name": service_name,
        "endpoint": f"tcp://localhost:{host_port}",
        "status": "HEALTHY" if probe_res.passed else f"UNHEALTHY ({probe_res.status})",
        "passed": probe_res.passed,
    }


def verify_node(node: NodeRecord) -> dict[str, Any]:
    """Execute standard health checks for a registered inference node."""
    return probe_inference_node(node)


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

    # Fallback to single-node from ai_platform.yaml if no nodes in registry yet
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


def verify_e2e_completion(
    model_name: str = "default", root_dir: Path | None = None
) -> dict[str, Any]:
    """Test LiteLLM /v1/chat/completions end-to-end to verify actual model backend routing."""
    import json
    import os
    import time
    import urllib.request

    target_root = root_dir or Path.cwd()
    env_file = target_root / ".env"
    master_key = os.environ.get("LITELLM_MASTER_KEY", "")
    if not master_key and env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("LITELLM_MASTER_KEY="):
                master_key = line.split("=", 1)[1].strip().strip('"').strip("'")
                break
    if not master_key:
        master_key = "sk-platform-test"

    url = "http://127.0.0.1:4000/v1/chat/completions"
    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": "E2E verification ping"}],
        "max_tokens": 10,
    }
    start = time.perf_counter()
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {master_key}",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            latency_ms = round((time.perf_counter() - start) * 1000.0, 1)
            return {
                "passed": resp.status == 200,
                "status": f"HTTP {resp.status} ({latency_ms}ms)",
                "latency_ms": latency_ms,
            }
    except Exception as e:
        return {
            "passed": False,
            "status": f"FAILED ({e})",
            "latency_ms": None,
        }


def verify_platform(resolved: ResolvedPlatform, root_dir: Path | None = None) -> dict[str, Any]:
    target_root = root_dir or Path.cwd()
    local_results: list[dict[str, Any]] = []
    for service_name in resolved.dependency_order:
        manifest = resolved.services[service_name]
        local_results.append(verify_service(service_name, manifest))

    remote_results = verify_remote_inference(resolved, root_dir=target_root)

    # E2E verification
    e2e_result = verify_e2e_completion(resolved.config.default_model, root_dir=target_root)

    all_local_ok = all(r["passed"] for r in local_results)
    all_remote_ok = all(r.get("passed", False) for r in remote_results) if remote_results else True

    return {
        "local_services": local_results,
        "remote_inference": remote_results,
        "e2e_completion": e2e_result,
        "is_ready": all_local_ok and all_remote_ok,
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
