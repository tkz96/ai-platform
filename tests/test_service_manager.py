from pathlib import Path

import pytest

from ai_platform.service_manager import ALLOWED_SERVICES, ServiceManager

PROJECT_ROOT = Path(__file__).parent.parent


def test_service_manager_whitelist_validation():
    sm = ServiceManager(PROJECT_ROOT)
    # Valid services should not raise ValueError for name validation
    sm._validate_service_name("postgres")
    sm._validate_service_name("litellm")

    # Invalid service name must raise ValueError
    with pytest.raises(ValueError) as exc_info:
        sm._validate_service_name("malicious_service; rm -rf /")
    assert "Invalid or unauthorized service name" in str(exc_info.value)


def test_list_services_returns_allowed_only():
    sm = ServiceManager(PROJECT_ROOT)
    services = sm.list_services()
    assert isinstance(services, list)
    for s in services:
        assert s["name"] in ALLOWED_SERVICES


def test_diagnose_service_dnsmasq():
    sm = ServiceManager(PROJECT_ROOT)
    diag = sm.diagnose_service("dnsmasq")
    assert diag.operation == "diagnose:dnsmasq"
    assert "pid_file" in diag.detected_state


def test_verify_platform_structure():
    from ai_platform.config import resolve_platform
    from ai_platform.verify import verify_platform

    resolved = resolve_platform(PROJECT_ROOT)
    results = verify_platform(resolved, root_dir=PROJECT_ROOT)
    assert "local_services" in results
    assert "remote_inference" in results
    assert "e2e_completion" in results
    assert "is_ready" in results
    assert isinstance(results["local_services"], list)
