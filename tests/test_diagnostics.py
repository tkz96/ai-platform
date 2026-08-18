from platform.diagnostics import DiagnosticResult, redact_text


def test_redact_text_secrets():
    assert redact_text("sk-enroll-1234567890abcdef123456") == "[REDACTED_TOKEN]"
    assert redact_text("POSTGRES_PASSWORD=mysecretpass") == "POSTGRES_PASSWORD=[REDACTED]"
    assert redact_text("postgresql://postgres:secret123@localhost:5432/db") == "postgresql://[REDACTED]:[REDACTED]@localhost:5432/db"


def test_diagnostic_result_redact():
    res = DiagnosticResult(
        operation="test_op",
        command="curl -H 'Authorization: Bearer sk-litellm-secret123456' http://localhost",
        exit_code=1,
        stdout="Output with POSTGRES_PASSWORD='dbpassword123'",
        stderr="Failed with token sk-enroll-9876543210fedcba",
        detected_state={"env": {"PASSWORD": "supersecret"}},
        recommendation="Check POSTGRES_PASSWORD setting",
        is_retryable=True,
    )
    redacted = res.redact()
    assert "sk-litellm" not in redacted.command
    assert "[REDACTED_TOKEN]" in redacted.command
    assert "dbpassword123" not in redacted.stdout
    assert "POSTGRES_PASSWORD=[REDACTED]" in redacted.stdout
    assert "sk-enroll" not in redacted.stderr
    assert "[REDACTED]" in redacted.detected_state["env"]["PASSWORD"]
    assert "supersecret" not in redacted.detected_state["env"]["PASSWORD"]


def test_diagnostic_result_to_json():
    res = DiagnosticResult(
        operation="test_json",
        command="echo sk-enroll-1234567890abcdef",
        exit_code=0,
    )
    json_str = res.to_json()
    assert "sk-enroll-1234567890abcdef" not in json_str
    assert "[REDACTED_TOKEN]" in json_str
