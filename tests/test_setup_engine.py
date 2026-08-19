"""Unit and integration tests for SetupEngine and setup web routes."""

from pathlib import Path

from fastapi.testclient import TestClient

from ai_platform.setup import SetupEngine, clean_ansi
from ai_platform.web.app import app

client = TestClient(app)
PROJECT_ROOT = Path(__file__).parent.parent


def test_clean_ansi():
    raw = "\x1b[32m✓ Success\x1b[0m\n\x1b[1;31mError message\x1b[0m"
    cleaned = clean_ansi(raw)
    assert cleaned == "✓ Success\nError message"


def test_setup_engine_phase_definitions():
    engine = SetupEngine(PROJECT_ROOT)
    phases = engine.get_phase_definitions()

    expected_ids = [
        "05-podman",
        "06a-networking",
        "07-secrets",
        "08-render",
        "09-deploy",
        "10-verify",
    ]

    actual_ids = [p.id for p in phases]
    assert actual_ids == expected_ids

    for p in phases:
        assert p.name
        assert p.description
        assert p.script
        assert p.category
        if p.id == "06a-networking":
            assert p.requires_sudo is True
        else:
            assert p.requires_sudo is False


def test_setup_engine_empirical_checks():
    engine = SetupEngine(PROJECT_ROOT)
    statuses = engine.get_all_phase_statuses()

    assert len(statuses) == 6
    for s in statuses:
        assert s.id in [
            "05-podman",
            "06a-networking",
            "07-secrets",
            "08-render",
            "09-deploy",
            "10-verify",
        ]
        assert s.status in ["completed", "pending", "failed", "in_progress"]
        assert isinstance(s.empirical_details, dict)


def test_setup_engine_readiness_summary():
    engine = SetupEngine(PROJECT_ROOT)
    summary = engine.get_readiness_summary()

    assert summary["total_phases"] == 6
    assert 0 <= summary["completed_phases"] <= 6
    assert 0 <= summary["percent_ready"] <= 100
    assert isinstance(summary["is_fully_provisioned"], bool)
    assert len(summary["phases"]) == 6


def test_setup_engine_audit_report():
    engine = SetupEngine(PROJECT_ROOT)
    audit = engine.run_full_audit()

    assert "timestamp" in audit
    assert audit["total_checks"] > 0
    assert audit["passed_checks"] >= 0
    assert audit["overall_health"] in ["HEALTHY", "DEGRADED", "ACTION_REQUIRED"]
    assert len(audit["checks"]) == audit["total_checks"]

    # Verify key audit categories exist
    categories = {i["category"] for i in audit["checks"]}
    assert "Host System" in categories
    assert "Tooling" in categories
    assert "Infrastructure" in categories
    assert "Networking" in categories


def test_setup_status_endpoint():
    response = client.get("/api/setup/status")
    assert response.status_code == 200
    assert "Platform setup & provisioning" in response.text
    assert "05-podman" in response.text
    assert "06a-networking" in response.text
    assert "07-secrets" in response.text
    assert "08-render" in response.text
    assert "09-deploy" in response.text
    assert "10-verify" in response.text


def test_setup_audit_endpoint():
    response = client.get("/api/setup/audit")
    assert response.status_code == 200
    assert "Platform health & readiness audit" in response.text
    assert "Apple Silicon Architecture" in response.text
    assert "Tooling" in response.text


def test_setup_reset_phase_endpoint():
    response = client.post(
        "/api/setup/reset-phase", data={"phase_id": "08-render", "confirm": "true"}
    )
    assert response.status_code == 200
    assert response.json()["success"] is True
    assert response.json()["phase_id"] == "08-render"


def test_setup_engine_auto_fix_phase():
    engine = SetupEngine(PROJECT_ROOT)
    res = engine.auto_fix_phase("08-render")
    assert "success" in res
    assert res["phase_id"] == "08-render"


def test_setup_auto_fix_endpoint():
    response = client.post("/api/setup/auto-fix-phase", data={"phase_id": "08-render"})
    assert response.status_code == 200
    assert response.json()["phase_id"] == "08-render"


def test_setup_engine_lock_contention():
    from ai_platform.setup.engine import _SETUP_LOCK

    engine = SetupEngine(PROJECT_ROOT)

    # Simulate lock being held by another thread/request
    assert _SETUP_LOCK.acquire(blocking=False)
    try:
        gen = engine.stream_phase_execution("08-render")
        first_event = next(gen)
        assert "event: error" in first_event
        assert "Another setup execution is currently in progress" in first_event

        all_gen = engine.stream_all_phases_execution()
        all_event = next(all_gen)
        assert "event: error" in all_event
        assert "Another setup execution is currently in progress" in all_event
    finally:
        _SETUP_LOCK.release()


def test_setup_stream_invalid_phase():
    engine = SetupEngine(PROJECT_ROOT)
    gen = engine.stream_phase_execution("99-nonexistent")
    first_event = next(gen)
    assert "event: error" in first_event
    assert "Invalid phase id" in first_event
