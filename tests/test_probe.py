import http.server
import json
import socket
import threading

from ai_platform.nodes import (
    HardwareSpecs,
    NodeIdentity,
    NodeRecord,
    NodeRuntimeState,
)
from ai_platform.probe import probe_http, probe_inference_node, probe_tcp


def test_probe_tcp_open_and_closed() -> None:
    # 1. Open TCP port
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]

    try:
        res = probe_tcp("127.0.0.1", port, timeout=2)
        assert res.passed is True
        assert res.status == "OPEN"
        assert res.latency_ms >= 0.0
    finally:
        server.close()

    # 2. Closed TCP port
    res_closed = probe_tcp("127.0.0.1", port, timeout=2)
    assert res_closed.passed is False
    assert "CLOSED" in res_closed.status


def test_probe_http_status_and_payload() -> None:
    class MockHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_GET(self) -> None:
            if self.path == "/health-ok":
                body = json.dumps({"status": "ok", "slots_idle": 1}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/health-loading":
                body = json.dumps({"status": "loading model"}).encode("utf-8")
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/health-error-field":
                body = json.dumps({"status": "error", "error": "CUDA OOM"}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

    server = http.server.HTTPServer(("127.0.0.1", 0), MockHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    try:
        base_url = f"http://127.0.0.1:{port}"

        # Standard check
        res = probe_http(f"{base_url}/health-ok")
        assert res.passed is True
        assert res.status == "HTTP 200"
        assert res.payload == {"status": "ok", "slots_idle": 1}

        # Strict llama contract: /health-ok
        res_ok = probe_http(f"{base_url}/health-ok", require_json_status_ok=True)
        assert res_ok.passed is True
        assert res_ok.status == "READY"
        assert res_ok.payload == {"status": "ok", "slots_idle": 1}

        # Strict llama contract: /health-loading (503)
        res_loading = probe_http(f"{base_url}/health-loading", require_json_status_ok=True)
        assert res_loading.passed is False
        assert "503" in res_loading.status
        assert res_loading.payload == {"status": "loading model"}

        # Strict llama contract: HTTP 200 with status != "ok"
        res_err_field = probe_http(f"{base_url}/health-error-field", require_json_status_ok=True)
        assert res_err_field.passed is False
        assert "status: error" in res_err_field.status

    finally:
        server.shutdown()
        server.server_close()


def test_probe_inference_node_helper() -> None:
    from ai_platform.nodes import NodeDesiredConfig

    node = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="linux-gpu",
            mac_address="00:11:22:33:44:55",
            reserved_ip="127.0.0.1",
        ),
        desired=NodeDesiredConfig(enabled=True),
        runtime=NodeRuntimeState(
            hardware=HardwareSpecs(cpu="Ryzen 9", ram_gb=64),
        ),
    )

    # When port is closed
    result = probe_inference_node(node)
    assert result["node_id"] == "node-01"
    assert result["passed"] is False
    assert result["status"] == "UNHEALTHY"
    assert "Ryzen 9" in result["hardware"]
