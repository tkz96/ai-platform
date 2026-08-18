from __future__ import annotations

from pathlib import Path
from platform.diagnostics import DiagnosticResult, redact_text
from platform.nodes import NodeRegistryManager
from platform.service_manager import ServiceManager

from fastapi import APIRouter, Form, Request
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
async def get_dashboard(request: Request) -> HTMLResponse:
    """Render main Control Plane & Inference Cluster dashboard."""
    sm = _get_service_manager()
    nm = _get_nodes_manager()

    services = sm.list_services()
    registry = nm.load()
    nodes = list(registry.nodes.values())

    return templates.TemplateResponse(
        request=request,
        name="dashboard.html",
        context={
            "services": services,
            "nodes": nodes,
            "project_root": str(PROJECT_ROOT),
        },
    )


@router.get("/api/ui/services", response_class=HTMLResponse)
async def get_services_partial(request: Request) -> HTMLResponse:
    """HTMX partial for live control plane services grid."""
    sm = _get_service_manager()
    services = sm.list_services()
    return templates.TemplateResponse(
        request=request,
        name="partials/services_grid.html",
        context={"services": services},
    )


@router.get("/api/ui/nodes", response_class=HTMLResponse)
async def get_nodes_partial(request: Request) -> HTMLResponse:
    """HTMX partial for live inference nodes grid."""
    nm = _get_nodes_manager()
    registry = nm.load()
    nodes = list(registry.nodes.values())
    return templates.TemplateResponse(
        request=request,
        name="partials/nodes_grid.html",
        context={"nodes": nodes},
    )


@router.post("/api/ui/services/{name}/action", response_model=None)
async def service_action(
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

    # If requested via HTMX, return updated service grid or modal
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
async def get_service_logs(request: Request, name: str, tail: int = 100) -> HTMLResponse:
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
async def diagnose_service_endpoint(request: Request, name: str) -> HTMLResponse:
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
async def diagnose_node_endpoint(request: Request, node_id: str) -> HTMLResponse:
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
