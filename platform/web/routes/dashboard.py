from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from platform.config import resolve_platform
from platform.diagnostics import DiagnosticResult, redact_text
from platform.nodes import NodeRegistryManager
from platform.probe import probe_http, probe_tcp
from platform.service_manager import ServiceManager

from fastapi import APIRouter, Form, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

router = APIRouter()

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
templates_dir = PROJECT_ROOT / "templates" / "web"
templates = Jinja2Templates(directory=str(templates_dir))


def _get_service_manager() -> ServiceManager:
    return ServiceManager(PROJECT_ROOT)


def _get_nodes_manager() -> NodeRegistryManager:
    return NodeRegistryManager(PROJECT_ROOT)


@router.get("/", response_class=HTMLResponse)
@router.get("/ui", response_class=HTMLResponse)
def get_dashboard(request: Request) -> HTMLResponse:
    """Render main Control Plane & Inference Cluster dashboard with rich platform state."""
    sm = _get_service_manager()
    nm = _get_nodes_manager()

    services = sm.list_services()
    registry = nm.load()
    nodes = list(registry.nodes.values())

    try:
        resolved = resolve_platform(PROJECT_ROOT)
        platform_info = {
            "name": resolved.platform.name,
            "domain": resolved.platform.domain,
            "default_model": resolved.platform.default_model,
            "subnet": resolved.platform.network.subnet,
            "mac_ip": resolved.platform.network.mac_ip,
            "node_ip_start": resolved.platform.network.node_ip_start,
            "dhcp_pool_start": resolved.platform.network.dhcp_pool_start,
            "dhcp_pool_end": resolved.platform.network.dhcp_pool_end,
            "versions": resolved.versions.services,
            "inference_config": resolved.platform.inference,
        }
    except Exception:
        platform_info = {
            "name": "ai-platform",
            "domain": "ai.internal",
            "default_model": "qwen3.6-35b-a3b",
            "subnet": "10.42.0.0/24",
            "mac_ip": "10.42.0.1",
            "node_ip_start": "10.42.0.2",
            "dhcp_pool_start": "10.42.0.100",
            "dhcp_pool_end": "10.42.0.200",
            "versions": {},
            "inference_config": None,
        }

    from platform.setup import SetupEngine

    setup_engine = SetupEngine(PROJECT_ROOT)
    setup_summary = setup_engine.get_readiness_summary()

    healthy_services_count = sum(1 for s in services if s.get("passed"))
    ready_nodes_count = sum(1 for n in nodes if n.runtime.status == "ready")

    # If setup is incomplete, default active tab to 'setup', otherwise 'services'
    initial_tab = "setup" if not setup_summary["is_fully_provisioned"] else "services"

    return templates.TemplateResponse(
        request=request,
        name="dashboard.html",
        context={
            "services": services,
            "nodes": nodes,
            "platform_info": platform_info,
            "setup_summary": setup_summary,
            "summary": setup_summary,
            "phases": setup_summary["phases"],
            "initial_tab": initial_tab,
            "healthy_services_count": healthy_services_count,
            "total_services_count": len(services),
            "ready_nodes_count": ready_nodes_count,
            "total_nodes_count": len(nodes),
            "project_root": str(PROJECT_ROOT),
        },
    )


@router.get("/api/ui/services", response_class=HTMLResponse)
def get_services_partial(
    request: Request,
    search: str = Query(default=""),
    status_filter: str = Query(default="all"),
) -> HTMLResponse:
    """HTMX partial for live control plane services grid with search and status filtering."""
    sm = _get_service_manager()
    services = sm.list_services()

    # Apply search filter
    if search:
        s_lower = search.lower().strip()
        services = [s for s in services if s_lower in s["name"].lower() or s_lower in s.get("endpoint", "").lower()]

    # Apply status filter
    if status_filter == "healthy":
        services = [s for s in services if s.get("passed")]
    elif status_filter == "unhealthy":
        services = [s for s in services if not s.get("passed") and not s["status"].startswith("STOPPED")]
    elif status_filter == "stopped":
        services = [s for s in services if s["status"].startswith("STOPPED")]

    return templates.TemplateResponse(
        request=request,
        name="partials/services_grid.html",
        context={"services": services, "search": search, "status_filter": status_filter},
    )


@router.get("/api/ui/nodes", response_class=HTMLResponse)
def get_nodes_partial(request: Request) -> HTMLResponse:
    """HTMX partial for live inference nodes grid."""
    nm = _get_nodes_manager()
    registry = nm.load()
    nodes = list(registry.nodes.values())
    return templates.TemplateResponse(
        request=request,
        name="partials/nodes_grid.html",
        context={"nodes": nodes},
    )


@router.get("/api/ui/health-matrix", response_class=HTMLResponse)
def get_health_matrix(request: Request) -> HTMLResponse:
    """HTMX partial for full cluster TCP/HTTP probe matrix using parallel probes."""
    import concurrent.futures

    targets = [
        {"name": "Caddy (Gateway)", "host": "127.0.0.1", "port": 8080, "type": "HTTP", "url": "http://127.0.0.1:8080"},
        {"name": "LiteLLM (API Proxy)", "host": "127.0.0.1", "port": 4000, "type": "HTTP", "url": "http://127.0.0.1:4000/health"},
        {"name": "Langfuse (Telemetry)", "host": "127.0.0.1", "port": 3000, "type": "HTTP", "url": "http://127.0.0.1:3000/api/public/health"},
        {"name": "Postgres (Relational DB)", "host": "127.0.0.1", "port": 5432, "type": "TCP", "url": None},
        {"name": "ClickHouse (Analytics)", "host": "127.0.0.1", "port": 8123, "type": "HTTP", "url": "http://127.0.0.1:8123/ping"},
        {"name": "Redis (Cache & Queue)", "host": "127.0.0.1", "port": 6379, "type": "TCP", "url": None},
        {"name": "llama-server (Inference 10.42.0.2)", "host": "10.42.0.2", "port": 8080, "type": "HTTP", "url": "http://10.42.0.2:8080/health"},
    ]

    def _probe_target(t: dict[str, Any]) -> dict[str, Any]:
        if t["type"] == "HTTP" and t["url"]:
            res = probe_http(t["url"], timeout=0.5)
        else:
            res = probe_tcp(t["host"], t["port"], timeout=0.5)

        return {
            "name": t["name"],
            "target": f"{t['host']}:{t['port']}",
            "type": t["type"],
            "passed": res.passed,
            "status": "ONLINE" if res.passed else res.status,
            "latency_ms": res.latency_ms,
            "error": res.error,
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets) or 1) as executor:
        future_to_idx = {executor.submit(_probe_target, t): i for i, t in enumerate(targets)}
        results_by_idx = {future_to_idx[f]: f.result() for f in concurrent.futures.as_completed(future_to_idx)}

    probes = [results_by_idx[i] for i in range(len(targets))]

    return templates.TemplateResponse(
        request=request,
        name="partials/health_matrix.html",
        context={"probes": probes},
    )


@router.post("/api/ui/services/{name}/action", response_model=None)
def service_action(
    request: Request,
    name: str,
    action: str = Form(...),
) -> HTMLResponse | JSONResponse:
    """Execute service lifecycle action (launch, stop, restart)."""
    sm = _get_service_manager()

    try:
        if action == "launch":
            diag = sm.launch_service(name)
        elif action == "stop":
            diag = sm.stop_service(name)
        elif action == "restart":
            diag = sm.restart_service(name)
        else:
            return JSONResponse(status_code=400, content={"error": f"Invalid action: {action}"})
    except Exception as e:
        diag = DiagnosticResult(
            operation=f"{action}:{name}",
            command=f"service action {action} {name}",
            exit_code=1,
            stderr=str(e),
            detected_state={"error": str(e)},
            recommendation="Inspect service logs or run diagnosis",
            is_retryable=True,
        ).redact()

    if diag.exit_code != 0:
        return templates.TemplateResponse(
            request=request,
            name="partials/diagnostic_modal.html",
            context={"diag": diag, "service_name": name},
        )

    services = sm.list_services()
    return templates.TemplateResponse(
        request=request,
        name="partials/services_grid.html",
        context={"services": services},
    )


@router.get("/api/ui/services/{name}/logs", response_class=HTMLResponse)
def get_service_logs(request: Request, name: str, tail: int = 100) -> HTMLResponse:
    """HTMX partial for log viewer drawer with automatic secret redaction."""
    sm = _get_service_manager()
    raw_logs = sm.get_logs(name, tail=tail)
    sanitized_logs = redact_text(raw_logs)

    return templates.TemplateResponse(
        request=request,
        name="partials/logs_drawer.html",
        context={
            "service_name": name,
            "logs": sanitized_logs,
            "tail": tail,
        },
    )


@router.get("/api/ui/services/{name}/diagnose", response_class=HTMLResponse)
def diagnose_service_endpoint(request: Request, name: str) -> HTMLResponse:
    """HTMX partial for diagnostic modal with empirical checks and secret redaction."""
    sm = _get_service_manager()
    try:
        diag = sm.diagnose_service(name)
    except Exception as e:
        diag = DiagnosticResult(
            operation=f"diagnose:{name}",
            command=f"diagnose {name}",
            exit_code=1,
            stderr=str(e),
            detected_state={"error": str(e)},
            recommendation="Verify service definition",
            is_retryable=True,
        ).redact()

    return templates.TemplateResponse(
        request=request,
        name="partials/diagnostic_modal.html",
        context={"diag": diag, "service_name": name},
    )


@router.get("/api/ui/nodes/{node_id}/diagnose", response_class=HTMLResponse)
def diagnose_node_endpoint(request: Request, node_id: str) -> HTMLResponse:
    """HTMX partial for node connectivity and llama-server diagnosis."""
    nm = _get_nodes_manager()
    registry = nm.load()
    node = registry.nodes.get(node_id)

    if not node:
        diag = DiagnosticResult(
            operation=f"diagnose_node:{node_id}",
            command="node search",
            exit_code=1,
            stderr=f"Node '{node_id}' not found in registry",
            detected_state={"registered": False},
            recommendation="Run ./bootstrap.sh connect-inference to enroll node",
            is_retryable=True,
        ).redact()
    else:
        cmd_str = (
            f"ssh {node.identity.ssh_user}@{node.identity.reserved_ip} "
            "systemctl status llama-server"
        )
        is_ready = node.runtime.status == "ready"
        diag = DiagnosticResult(
            operation=f"diagnose_node:{node_id}",
            command=cmd_str,
            exit_code=0 if is_ready else 1,
            stdout=f"Node '{node_id}' ({node.identity.hostname}) IP: {node.identity.reserved_ip}",
            stderr="" if is_ready else f"Node state is '{node.runtime.status}'",
            detected_state={
                "node_id": node.identity.id,
                "hostname": node.identity.hostname,
                "reserved_ip": node.identity.reserved_ip,
                "status": node.runtime.status,
                "cpu": node.runtime.hardware.cpu if node.runtime.hardware else "Unknown",
                "ram_gb": str(node.runtime.hardware.ram_gb) if node.runtime.hardware else "0",
            },
            recommendation="Node operating normally"
            if is_ready
            else "Verify SSH connectivity and physical Ethernet link",
            is_retryable=True,
        ).redact()

    return templates.TemplateResponse(
        request=request,
        name="partials/diagnostic_modal.html",
        context={"diag": diag, "service_name": node_id},
    )


@router.post("/api/ui/test-completion", response_class=HTMLResponse)
def test_completion(
    request: Request,
    prompt: str = Form(default="Ping test from AI Platform dashboard. Respond in 5 words."),
    target: str = Form(default="litellm"),
    temperature: float = Form(default=0.7),
    max_tokens: int = Form(default=64),
) -> HTMLResponse:
    """HTMX endpoint to test real LLM inference completion and return live response metrics."""
    endpoint_url = "http://127.0.0.1:4000/v1/chat/completions" if target == "litellm" else "http://10.42.0.2:8080/v1/chat/completions"

    payload = {
        "model": "qwen3.6-35b-a3b",
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }

    start_time = time.perf_counter()
    req_bytes = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        endpoint_url,
        data=req_bytes,
        headers={"Content-Type": "application/json", "Authorization": "Bearer sk-platform-test"},
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            latency_ms = round((time.perf_counter() - start_time) * 1000.0, 1)
            resp_data = json.loads(resp.read().decode("utf-8"))
            content = resp_data["choices"][0]["message"]["content"]
            usage = resp_data.get("usage", {})
            tokens = usage.get("total_tokens", len(content.split()))

            result = {
                "success": True,
                "content": content,
                "latency_ms": latency_ms,
                "target": target,
                "endpoint": endpoint_url,
                "tokens": tokens,
                "prompt": prompt,
                "raw_response": json.dumps(resp_data, indent=2),
            }
    except Exception as e:
        latency_ms = round((time.perf_counter() - start_time) * 1000.0, 1)
        result = {
            "success": False,
            "content": f"Connection/Inference error: {e}",
            "latency_ms": latency_ms,
            "target": target,
            "endpoint": endpoint_url,
            "tokens": 0,
            "prompt": prompt,
            "raw_response": str(e),
        }

    return templates.TemplateResponse(
        request=request,
        name="partials/playground_result.html",
        context={"result": result},
    )
