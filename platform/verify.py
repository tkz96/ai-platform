import urllib.error
import urllib.request
from platform.config import ResolvedPlatform, ServiceManifest
from typing import Any

from rich.console import Console
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


def verify_service(service_name: str, manifest: ServiceManifest) -> dict[str, Any]:
    if not manifest.health or not manifest.ports:
        return {
            "name": service_name,
            "status": "HEALTHY (No HTTP check configured)",
            "passed": True,
        }

    host_port = manifest.ports[0].host_port
    endpoint = manifest.health.endpoint or "/"
    target_url = f"http://localhost:{host_port}{endpoint}"

    passed, message = check_endpoint(target_url)
    return {
        "name": service_name,
        "endpoint": target_url,
        "status": "HEALTHY" if passed else f"UNHEALTHY ({message})",
        "passed": passed,
    }


def verify_platform(resolved: ResolvedPlatform, print_table: bool = True) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for service_name in resolved.dependency_order:
        manifest = resolved.services[service_name]
        results.append(verify_service(service_name, manifest))

    if print_table:
        console = Console()
        table = Table(title="AI Platform Service Status")
        table.add_column("Service", style="cyan", no_wrap=True)
        table.add_column("Endpoint", style="blue")
        table.add_column("Status", style="bold")

        for r in results:
            status_style = "green" if r["passed"] else "red"
            table.add_row(
                r["name"],
                r.get("endpoint", "N/A"),
                f"[{status_style}]{r['status']}[/{status_style}]",
            )

        console.print(table)

    return results
