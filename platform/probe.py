from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from platform.nodes import NodeRecord
from typing import Any


@dataclass(frozen=True)
class ProbeResult:
    """Telemetry result of a TCP or HTTP network probe."""

    passed: bool
    status: str
    latency_ms: float = 0.0
    payload: dict[str, Any] | None = None
    error: str | None = None


def probe_tcp(host: str, port: int, timeout: int = 5) -> ProbeResult:
    """Probe network connectivity to a TCP port and measure handshake latency."""
    start_time = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            latency = (time.perf_counter() - start_time) * 1000.0
            return ProbeResult(
                passed=True,
                status="OPEN",
                latency_ms=round(latency, 2),
            )
    except Exception as e:
        latency = (time.perf_counter() - start_time) * 1000.0
        return ProbeResult(
            passed=False,
            status=f"CLOSED ({e})",
            latency_ms=round(latency, 2),
            error=str(e),
        )


def probe_http(
    url: str,
    timeout: int = 5,
    require_json_status_ok: bool = False,
) -> ProbeResult:
    """Probe an HTTP health endpoint, validate status codes and optional JSON payload contracts."""
    start_time = time.perf_counter()
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "AI-Platform-Verifier/1.0", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            latency = (time.perf_counter() - start_time) * 1000.0
            status_code = resp.status
            body_bytes = resp.read()

            parsed_payload: dict[str, Any] | None = None
            try:
                if body_bytes:
                    data = json.loads(body_bytes.decode("utf-8"))
                    if isinstance(data, dict):
                        parsed_payload = data
            except Exception:
                pass

            if require_json_status_ok:
                if status_code != 200:
                    return ProbeResult(
                        passed=False,
                        status=f"UNHEALTHY (HTTP {status_code})",
                        latency_ms=round(latency, 2),
                        payload=parsed_payload,
                        error=f"Expected HTTP 200, got {status_code}",
                    )
                if not parsed_payload or parsed_payload.get("status") != "ok":
                    status_val = parsed_payload.get("status") if parsed_payload else "non-JSON"
                    return ProbeResult(
                        passed=False,
                        status=f"UNHEALTHY (status: {status_val})",
                        latency_ms=round(latency, 2),
                        payload=parsed_payload,
                        error=f"Payload status is '{status_val}', expected 'ok'",
                    )
                return ProbeResult(
                    passed=True,
                    status="READY",
                    latency_ms=round(latency, 2),
                    payload=parsed_payload,
                )

            if 200 <= status_code < 400:
                return ProbeResult(
                    passed=True,
                    status=f"HTTP {status_code}",
                    latency_ms=round(latency, 2),
                    payload=parsed_payload,
                )
            return ProbeResult(
                passed=False,
                status=f"HTTP {status_code}",
                latency_ms=round(latency, 2),
                payload=parsed_payload,
                error=f"Unexpected status code {status_code}",
            )

    except urllib.error.HTTPError as e:
        latency = (time.perf_counter() - start_time) * 1000.0
        parsed_payload = None
        try:
            body = e.read().decode("utf-8")
            if body:
                parsed_payload = json.loads(body)
        except Exception:
            pass
        return ProbeResult(
            passed=False,
            status=f"HTTP {e.code}",
            latency_ms=round(latency, 2),
            payload=parsed_payload,
            error=str(e),
        )
    except Exception as e:
        latency = (time.perf_counter() - start_time) * 1000.0
        return ProbeResult(
            passed=False,
            status=f"UNREACHABLE ({e})",
            latency_ms=round(latency, 2),
            error=str(e),
        )


def probe_inference_node(node: NodeRecord, timeout: int = 5) -> dict[str, Any]:
    """Execute standard health and readiness checks for an inference node."""
    ip = node.identity.reserved_ip
    model_assign = node.desired.models[0] if node.desired.models else None
    port = model_assign.port if model_assign else 8080
    health_endpoint = model_assign.health_endpoint if model_assign else "/health"
    proto = model_assign.protocol if model_assign else "http"
    model_name = node.runtime.active_model or (
        model_assign.model_name if model_assign else "Unknown"
    )

    tcp_res = probe_tcp(ip, port, timeout=timeout)
    health_url = f"{proto}://{ip}:{port}{health_endpoint}"
    http_res = probe_http(health_url, timeout=timeout, require_json_status_ok=True)

    # Format hardware summary
    hw_str = "CPU Mode"
    if node.runtime.hardware and node.runtime.hardware.gpus:
        gpus = node.runtime.hardware.gpus
        gpu_summary = ", ".join(f"{g.name} ({g.vram_gb}GB)" for g in gpus)
        hw_str = f"{gpu_summary} ({node.runtime.hardware.ram_gb}GB RAM)"
    elif node.runtime.hardware:
        hw_str = f"{node.runtime.hardware.cpu} ({node.runtime.hardware.ram_gb}GB RAM)"

    is_ready = tcp_res.passed and http_res.passed
    return {
        "node_id": node.identity.id,
        "ip": ip,
        "hardware": hw_str,
        "active_model": model_name,
        "tcp_passed": tcp_res.passed,
        "tcp_status": tcp_res.status,
        "http_passed": http_res.passed,
        "http_status": http_res.status,
        "http_latency_ms": http_res.latency_ms,
        "status": "READY" if is_ready else "UNHEALTHY",
        "passed": is_ready,
        "payload": http_res.payload,
    }
