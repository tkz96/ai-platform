from __future__ import annotations

import hmac
import http.server
import json
import os
import signal
import threading
from pathlib import Path
from platform.nodes import (
    GPUInfo,
    HardwareSpecs,
    NodeRegistryManager,
)
from typing import Any


def get_session_token(root_dir: Path) -> str:
    """Read the active session token from secrets/enrollment_token."""
    token_file = root_dir / "secrets" / "enrollment_token"
    if token_file.exists():
        return token_file.read_text().strip()
    return ""


def get_cluster_public_key(root_dir: Path) -> str:
    """Read the cluster orchestrator SSH public key."""
    pub_key_file = root_dir / "secrets" / "ssh" / "cluster_orchestrator_key.pub"
    if pub_key_file.exists():
        return pub_key_file.read_text().strip()
    return ""


def notify_dnsmasq_reload(root_dir: Path) -> None:
    """Signal dnsmasq to reload dhcp-hostsfile (state/dnsmasq.hosts)."""
    pid_file = root_dir / "state" / "dnsmasq.pid"
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, signal.SIGHUP)
        except Exception:
            pass


class EnrollmentRequestHandler(http.server.BaseHTTPRequestHandler):
    root_dir: Path

    def log_message(self, format: str, *args: Any) -> None:
        # Suppress noisy standard logging or customize
        pass

    def _send_json(self, status_code: int, data: dict[str, Any]) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        if path in ("/node-enroll.sh", "/enroll"):
            script_path = self.root_dir / "scripts" / "inference" / "node-enroll.sh"
            if not script_path.exists():
                script_path = self.root_dir / "node-enroll.sh"
            if script_path.exists():
                content = script_path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/x-shellscript")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self._send_json(
                    404, {"status": "error", "error": "node-enroll.sh script not found"}
                )
        elif path == "/api/enroll/status":
            registry = NodeRegistryManager(self.root_dir).load()
            self._send_json(200, {"status": "ok", "enrolled_count": len(registry.nodes)})
        else:
            self._send_json(404, {"status": "error", "error": f"Endpoint not found: {path}"})

    def do_POST(self) -> None:
        path = self.path.split("?")[0]
        if path == "/api/enroll":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length <= 0 or content_length > 65536:
                self._send_json(400, {"status": "error", "error": "Invalid payload size"})
                return

            body = self.rfile.read(content_length)
            try:
                data = json.loads(body.decode("utf-8"))
            except Exception:
                self._send_json(400, {"status": "error", "error": "Malformed JSON payload"})
                return

            # Constant-time token verification
            received_token = str(data.get("token", ""))
            expected_token = get_session_token(self.root_dir)
            if not expected_token or not hmac.compare_digest(received_token, expected_token):
                self._send_json(
                    403, {"status": "error", "error": "Invalid or expired session token"}
                )
                return

            hostname = str(data.get("hostname", "unknown-node"))
            mac_address = str(data.get("mac_address", "")).strip()
            ssh_user = str(data.get("ssh_user", "ubuntu")).strip()
            ssh_host_key = str(data.get("ssh_host_key", "")).strip()
            current_ip = str(data.get("current_ip", "")).strip() or None
            replace_node_id = data.get("replace_node_id")

            if not mac_address:
                self._send_json(400, {"status": "error", "error": "Missing mac_address"})
                return

            # Parse hardware specs if provided
            hw_dict = data.get("hardware", {})
            hw_specs = None
            if hw_dict and isinstance(hw_dict, dict):
                gpus: list[GPUInfo] = []
                for g in hw_dict.get("gpus", []):
                    if isinstance(g, dict) and "name" in g:
                        gpus.append(
                            GPUInfo(
                                name=str(g.get("name", "")),
                                vram_gb=int(g.get("vram_gb", 0)),
                                driver_version=g.get("driver_version"),
                                count=int(g.get("count", 1)),
                            )
                        )
                hw_specs = HardwareSpecs(
                    cpu=str(hw_dict.get("cpu", "Generic CPU")),
                    ram_gb=int(hw_dict.get("ram_gb", 0)),
                    gpus=gpus,
                )

            # Register node and synchronize infrastructure
            manager = NodeRegistryManager(self.root_dir)
            node_record, is_new = manager.enroll_node(
                hostname=hostname,
                mac_address=mac_address,
                ssh_user=ssh_user,
                ssh_host_key=ssh_host_key,
                current_ip=current_ip,
                hardware=hw_specs,
                replace_node_id=replace_node_id,
            )

            # Return success response with cluster public key
            cluster_pub_key = get_cluster_public_key(self.root_dir)
            self._send_json(
                200,
                {
                    "status": "ok",
                    "node_id": node_record.identity.id,
                    "reserved_ip": node_record.identity.reserved_ip,
                    "cluster_public_key": cluster_pub_key,
                },
            )
        else:
            self._send_json(404, {"status": "error", "error": f"Endpoint not found: {path}"})


class DualStackServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def make_enrollment_server(
    root_dir: Path, host: str = "10.42.0.1", port: int = 8765
) -> DualStackServer:
    """Create enrollment HTTP server bound to the specified interface and port."""
    handler_cls = type(
        "ConfiguredEnrollmentHandler",
        (EnrollmentRequestHandler,),
        {"root_dir": root_dir},
    )
    return DualStackServer((host, port), handler_cls)


def run_enrollment_listener_background(
    root_dir: Path, host: str = "10.42.0.1", port: int = 8765
) -> tuple[DualStackServer, threading.Thread]:
    """Start the enrollment HTTP server in a background thread."""
    server = make_enrollment_server(root_dir, host=host, port=port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread
