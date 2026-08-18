from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from typing import Any

SECRET_PATTERNS = [
    # API / Enrollment tokens
    (r"sk-[a-zA-Z0-9_-]{12,}", "[REDACTED_TOKEN]"),
    # SSH private keys
    (r"-----BEGIN [A-Z ]+ PRIVATE KEY-----\s*[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----", "[REDACTED_SSH_KEY]"),
    # Common env secrets
    (r"(?i)(password|secret|key|token|auth)\s*[:=]\s*['\"]?([^\s'\"]+)['\"]?", r"\1=[REDACTED]"),
    # Connection URIs with credentials
    (r"postgresql://[^:]+:[^@]+@", "postgresql://[REDACTED]:[REDACTED]@"),
    (r"clickhouse://[^:]+:[^@]+@", "clickhouse://[REDACTED]:[REDACTED]@"),
]

SENSITIVE_KEY_PATTERN = re.compile(r"(?i)(password|secret|key|token|auth)")


def redact_text(text: str) -> str:
    """Sanitize sensitive secrets from text string."""
    if not text:
        return ""
    sanitized = text
    for pattern, replacement in SECRET_PATTERNS:
        sanitized = re.sub(pattern, replacement, sanitized)
    return sanitized


def redact_obj(obj: Any, key_context: str = "") -> Any:
    """Recursively redact strings in dicts, lists, and scalars."""
    if isinstance(obj, str):
        if key_context and SENSITIVE_KEY_PATTERN.search(key_context):
            return "[REDACTED]"
        return redact_text(obj)
    elif isinstance(obj, dict):
        return {k: redact_obj(v, key_context=str(k)) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [redact_obj(v, key_context=key_context) for v in obj]
    return obj


@dataclass
class DiagnosticResult:
    """Standardized result abstraction for operational commands and health diagnostics."""
    operation: str
    command: str = ""
    exit_code: int = 0
    stdout: str = ""
    stderr: str = ""
    detected_state: dict[str, Any] = field(default_factory=dict)
    recommendation: str = ""
    is_retryable: bool = True

    def redact(self) -> DiagnosticResult:
        """Return a copy of this result with all secrets redacted."""
        return DiagnosticResult(
            operation=redact_text(self.operation),
            command=redact_text(self.command),
            exit_code=self.exit_code,
            stdout=redact_text(self.stdout),
            stderr=redact_text(self.stderr),
            detected_state=redact_obj(self.detected_state),
            recommendation=redact_text(self.recommendation),
            is_retryable=self.is_retryable,
        )

    def to_dict(self) -> dict[str, Any]:
        """Return dictionary representation with secrets redacted."""
        return asdict(self.redact())

    def to_json(self, indent: int | None = None) -> str:
        """Return JSON representation with secrets redacted."""
        return json.dumps(self.to_dict(), indent=indent)
