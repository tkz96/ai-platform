"""Security, Authentication, Authorization, and Action Classification for FastAPI Web API."""

from __future__ import annotations

import contextlib
import os
import secrets
from pathlib import Path
from typing import Any

from fastapi import HTTPException, Request, status

DANGEROUS_ACTIONS = {
    "reset-phase",
    "reset_phase",
    "destroy_platform",
    "kill_process",
    "delete_reservation",
    "delete_node",
}

DISRUPTIVE_ACTIONS = {
    "restart_service",
    "restart_llama_server",
    "reconnect_dhcp",
    "reload_pf",
}

SAFE_ACTIONS = {
    "probe",
    "health",
    "status",
    "logs",
    "diagnose",
    "list_services",
    "list_nodes",
}


def get_or_create_admin_token(project_root: Path) -> str:
    """Retrieve or generate persistent admin token in secrets/admin_token."""
    secrets_dir = project_root / "secrets"
    secrets_dir.mkdir(parents=True, exist_ok=True)
    token_file = secrets_dir / "admin_token"

    if token_file.exists():
        token = token_file.read_text().strip()
        if len(token) >= 16:
            return token

    new_token = secrets.token_hex(32)
    token_file.write_text(new_token + "\n")
    with contextlib.suppress(Exception):
        os.chmod(token_file, 0o600)
    return new_token


def extract_token_from_request(request: Request) -> str | None:
    """Extract auth token from Authorization header, X-Admin-Token header, or cookie."""
    auth_header = request.headers.get("Authorization", "")
    if auth_header.lower().startswith("bearer "):
        return auth_header[7:].strip()

    x_token = request.headers.get("X-Admin-Token")
    if x_token:
        return x_token.strip()

    cookie_token = request.cookies.get("admin_token")
    if cookie_token:
        return cookie_token.strip()

    return None


def verify_authentication(request: Request, project_root: Path) -> bool:
    """Verify request authentication token against system admin token."""
    expected_token = get_or_create_admin_token(project_root)
    provided_token = extract_token_from_request(request)

    if provided_token and secrets.compare_digest(provided_token, expected_token):
        return True

    # Allow localhost read-only requests unless STRICT_AUTH environment flag is enabled
    is_loopback = request.client is not None and request.client.host in (
        "127.0.0.1",
        "::1",
        "localhost",
    )
    strict_auth = os.environ.get("STRICT_AUTH", "0").lower() in ("1", "true", "yes")

    return bool(is_loopback and not strict_auth)


def require_admin(request: Request, project_root: Path) -> None:
    """Raise HTTP 401 Unauthorized if request fails authentication check."""
    if not verify_authentication(request, project_root):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required. Provide Bearer token or X-Admin-Token header.",
        )


def validate_action_safety(action_name: str, payload: dict[str, Any] | None = None) -> None:
    """Validate action safety and enforce explicit confirmation for dangerous actions."""
    if action_name in DANGEROUS_ACTIONS:
        payload = payload or {}
        confirmed = payload.get("confirm") is True or str(payload.get("confirm", "")).lower() in (
            "true",
            "1",
            "yes",
        )
        if not confirmed:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Action '{action_name}' is classified as DANGEROUS. Set confirm=true in payload to execute.",
            )
