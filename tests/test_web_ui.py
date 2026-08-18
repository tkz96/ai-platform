from platform.web.app import app

from fastapi.testclient import TestClient

client = TestClient(app)


def test_dashboard_endpoint():
    response = client.get("/")
    assert response.status_code == 200
    assert "AI Platform Control Plane" in response.text
    assert "Control Plane Services" in response.text


def test_ui_alias_endpoint():
    response = client.get("/ui")
    assert response.status_code == 200
    assert "AI Platform Control Plane" in response.text


def test_services_partial_endpoint():
    response = client.get("/api/ui/services")
    assert response.status_code == 200
    assert "postgres" in response.text
    assert "litellm" in response.text


def test_nodes_partial_endpoint():
    response = client.get("/api/ui/nodes")
    assert response.status_code == 200


def test_service_logs_endpoint():
    response = client.get("/api/ui/services/litellm/logs")
    assert response.status_code == 200
    assert "Container Logs: litellm" in response.text


def test_service_diagnose_endpoint():
    response = client.get("/api/ui/services/litellm/diagnose")
    assert response.status_code == 200
    assert "Diagnostic Report: litellm" in response.text
    assert "Command Executed" in response.text


def test_node_diagnose_endpoint():
    response = client.get("/api/ui/nodes/node-01/diagnose")
    assert response.status_code == 200
    assert "Diagnostic Report: node-01" in response.text


def test_service_action_invalid():
    response = client.post("/api/ui/services/litellm/action", data={"action": "invalid_action"})
    assert response.status_code == 400
