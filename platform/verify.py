import socket
import urllib.error
import urllib.request
from platform.config import ResolvedPlatform, ServiceManifest
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


def verify_remote_inference(resolved: ResolvedPlatform) -> list[dict[str, Any]]:
    inf = resolved.config.inference
    results: list[dict[str, Any]] = []

    # 1. TCP connectivity
    tcp_passed, tcp_msg = check_tcp_port(inf.host, inf.port)
    results.append(
        {
            "name": "inference_tcp",
            "endpoint": f"tcp://{inf.host}:{inf.port}",
            "status": "HEALTHY" if tcp_passed else f"UNHEALTHY ({tcp_msg})",
            "passed": tcp_passed,
        }
    )

    # 2. HTTP health check
    health_url = f"{inf.protocol}://{inf.host}:{inf.port}{inf.health_endpoint}"
    http_passed, http_msg = check_endpoint(health_url)
    results.append(
        {
            "name": "inference_api",
            "endpoint": health_url,
            "status": "HEALTHY" if http_passed else f"UNHEALTHY ({http_msg})",
            "passed": http_passed,
        }
    )

    return results


def verify_platform(resolved: ResolvedPlatform) -> dict[str, Any]:
    local_results: list[dict[str, Any]] = []
    for service_name in resolved.dependency_order:
        manifest = resolved.services[service_name]
        local_results.append(verify_service(service_name, manifest))

    remote_results = verify_remote_inference(resolved)

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

    remote_table = Table(title="Remote Inference Node")
    remote_table.add_column("Check", style="cyan", no_wrap=True)
    remote_table.add_column("Endpoint", style="blue")
    remote_table.add_column("Status", style="bold")

    for r in remote_results:
        status_style = "green" if r["passed"] else "yellow"
        remote_table.add_row(
            r["name"],
            r.get("endpoint", "N/A"),
            f"[{status_style}]{r['status']}[/{status_style}]",
        )

    return Group(local_table, remote_table)
