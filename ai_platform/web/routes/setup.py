"""FastAPI Setup & Provisioning Router.

Exposes REST and SSE endpoints for running installation phases,
retrieving empirical checklist statuses, and performing system-wide health audits.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, Query, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.templating import Jinja2Templates

from ai_platform.setup import SetupEngine, get_canonical_phase_definitions
from ai_platform.web.security import validate_action_safety

router = APIRouter()

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
templates_dir = PROJECT_ROOT / "templates" / "web"
templates = Jinja2Templates(directory=str(templates_dir))


def _get_setup_engine() -> SetupEngine:
    return SetupEngine(PROJECT_ROOT)


@router.get("/api/setup/status", response_class=HTMLResponse)
def get_setup_status_partial(request: Request) -> HTMLResponse:
    """HTMX partial rendering live empirical phase checklist and readiness score."""
    engine = _get_setup_engine()
    summary = engine.get_readiness_summary()

    return templates.TemplateResponse(
        request=request,
        name="partials/setup_checklist.html",
        context={
            "summary": summary,
            "phases": summary["phases"],
            "percent_ready": summary["percent_ready"],
            "is_fully_provisioned": summary["is_fully_provisioned"],
            "next_phase_id": summary["next_phase_id"],
            "next_phase_name": summary["next_phase_name"],
        },
    )


@router.get("/api/setup/stream")
def stream_setup_execution(
    phase: str = Query(default="all"),
) -> StreamingResponse:
    """Server-Sent Events (SSE) endpoint streaming real-time terminal stdout/stderr for phase execution."""
    engine = _get_setup_engine()

    valid_ids = {p.id for p in get_canonical_phase_definitions()} | {"all"}
    if phase not in valid_ids:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid phase ID '{phase}'. Allowed phase IDs: {sorted(list(valid_ids))}",
        )

    if phase == "all":
        generator = engine.stream_all_phases_execution()
    else:
        generator = engine.stream_phase_execution(phase)

    return StreamingResponse(
        generator,
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/api/setup/audit", response_class=HTMLResponse)
def get_audit_report_partial(request: Request) -> HTMLResponse:
    """HTMX partial rendering comprehensive system diagnostic audit report."""
    engine = _get_setup_engine()
    audit = engine.run_full_audit()

    return templates.TemplateResponse(
        request=request,
        name="partials/audit_report.html",
        context={"audit": audit},
    )


@router.post("/api/setup/reset-phase")
def reset_phase_state(
    phase_id: str = Form(...),
    confirm: bool = Form(default=True),
) -> JSONResponse:
    """Reset / clear state for a specific phase."""
    valid_ids = {p.id for p in get_canonical_phase_definitions()}
    if phase_id not in valid_ids:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid phase ID '{phase_id}'. Allowed phase IDs: {sorted(list(valid_ids))}",
        )

    validate_action_safety("reset-phase", {"confirm": confirm})

    engine = _get_setup_engine()
    state_file = engine.state_file
    if state_file.exists():
        try:
            lines = state_file.read_text().splitlines()
            filtered = [line for line in lines if not line.startswith(f"{phase_id}:")]
            state_file.write_text("\n".join(filtered) + "\n")
        except Exception:
            pass

    return JSONResponse(content={"success": True, "phase_id": phase_id})
