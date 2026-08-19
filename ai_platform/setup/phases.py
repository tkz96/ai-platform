"""Declarative setup phase definitions and structures."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class PhaseIssue:
    symptom: str
    root_cause: str
    fix_steps: list[str]
    quick_fix_command: str | None = None


@dataclass
class PhaseDefinition:
    id: str
    name: str
    script: str
    description: str
    category: str
    requires_sudo: bool
    common_issues: list[PhaseIssue] = field(default_factory=list)


@dataclass
class PhaseStatus:
    id: str
    name: str
    description: str
    category: str
    requires_sudo: bool
    status: str  # "completed" | "pending" | "failed" | "in_progress" | "aborted" | "blocked"
    empirical_details: dict[str, Any]
    error_message: str | None = None
    remediation: dict[str, Any] | None = None


def get_canonical_phase_definitions() -> list[PhaseDefinition]:
    """Return the canonical ordered list of dashboard provisioning phases."""
    return [
        PhaseDefinition(
            id="05-podman",
            name="Podman Machine Initialization",
            script="05-podman.sh",
            description="Initializes and launches the rootless Linux VM (ai-platform) for running OCI containers.",
            category="Infrastructure",
            requires_sudo=False,
            common_issues=[
                PhaseIssue(
                    symptom="Podman machine cannot start / gvproxy socket error",
                    root_cause="Another Podman machine or stale process holds the VM lock socket.",
                    fix_steps=[
                        "Stop any zombie podman processes: `killall podman podman-mac-helper gvproxy 2>/dev/null || true`",
                        "Check machine status: `podman machine list`",
                        "Restart the machine cleanly: `podman machine stop ai-platform && podman machine start ai-platform`",
                    ],
                    quick_fix_command="podman machine stop ai-platform 2>/dev/null; podman machine start ai-platform",
                ),
                PhaseIssue(
                    symptom="Insufficient disk space or memory allocated to VM",
                    root_cause="Host machine low on disk or RAM for 60GB VM image.",
                    fix_steps=[
                        "Free at least 15GB of disk space on your Mac.",
                        "Recreate machine with smaller disk if needed: `podman machine rm -f ai-platform` then re-run phase.",
                    ],
                    quick_fix_command="podman machine list",
                ),
            ],
        ),
        PhaseDefinition(
            id="06a-networking",
            name="Private Ethernet & NAT Gateway",
            script="06a-networking.sh",
            description="Configures Mac Ethernet IP (10.42.0.1), macOS PF NAT packet forwarding, and dnsmasq DHCP.",
            category="Networking",
            requires_sudo=True,
            common_issues=[
                PhaseIssue(
                    symptom="No active physical Ethernet interface detected",
                    root_cause="Ethernet cable is unplugged, or Thunderbolt adapter not connected.",
                    fix_steps=[
                        "Plug Ethernet cable directly between Mac Mini and Linux GPU Node (or into dedicated switch).",
                        "Verify link carrier indicator lights are green/amber on Ethernet port.",
                        "Check macOS network interfaces: `networksetup -listallhardwareports`",
                    ],
                    quick_fix_command="networksetup -listallhardwareports",
                ),
                PhaseIssue(
                    symptom="PF NAT rules failed to load or sudo permission denied",
                    root_cause="Sudo credential timed out or macOS packet filter syntax error.",
                    fix_steps=[
                        "Run `sudo pfctl -ef /etc/pf.conf` in your terminal to ensure PF is operational.",
                        "Verify `/etc/resolver/internal` file permissions.",
                    ],
                    quick_fix_command="sudo pfctl -s info",
                ),
                PhaseIssue(
                    symptom="dnsmasq port 53 / 67 conflict",
                    root_cause="Another DNS or DHCP daemon (like Internet Sharing) is already running.",
                    fix_steps=[
                        "Disable macOS Internet Sharing in System Settings > General > Sharing.",
                        "Check listeners: `sudo lsof -i :53`",
                    ],
                    quick_fix_command="sudo lsof -i :53",
                ),
            ],
        ),
        PhaseDefinition(
            id="07-secrets",
            name="Secrets & Cluster Keys Generation",
            script="07-secrets.sh",
            description="Generates cryptographically secure API keys, PostgreSQL/ClickHouse/Redis credentials, and cluster SSH keypair.",
            category="Security",
            requires_sudo=False,
            common_issues=[
                PhaseIssue(
                    symptom="Permission denied writing to .env or secrets/",
                    root_cause="Directory permissions restricted or owned by root.",
                    fix_steps=[
                        "Take ownership of workspace directory: `sudo chown -R $(whoami) .`",
                        "Verify write permissions: `touch .env`",
                    ],
                    quick_fix_command="chmod -R u+rw .",
                ),
            ],
        ),
        PhaseDefinition(
            id="08-render",
            name="Configuration & Template Rendering",
            script="08-render.sh",
            description="Validates platform.yaml schemas and generates compose.yaml, Caddyfile, and LiteLLM configurations.",
            category="Configuration",
            requires_sudo=False,
            common_issues=[
                PhaseIssue(
                    symptom="YAML schema validation error in platform.yaml",
                    root_cause="Syntax error, invalid IP format, or missing required field in platform.yaml.",
                    fix_steps=[
                        "Check platform.yaml syntax: `yq eval '.' platform.yaml`",
                        "Restore default template if broken: `git checkout platform.yaml`",
                    ],
                    quick_fix_command="uv run python bootstrap.py render --dry-run",
                ),
            ],
        ),
        PhaseDefinition(
            id="09-deploy",
            name="Control Plane Services Deployment",
            script="09-deploy.sh",
            description="Pulls pinned container images and starts Postgres, ClickHouse, Redis, Langfuse, LiteLLM, and Caddy.",
            category="Deployment",
            requires_sudo=False,
            common_issues=[
                PhaseIssue(
                    symptom="Image pull timed out or registry rate limit",
                    root_cause="Internet connectivity drop or slow connection while pulling container images.",
                    fix_steps=[
                        "Verify internet connectivity from host and Podman VM.",
                        "Test pull manually: `podman pull docker.io/library/postgres:16-alpine`",
                        "Retry the phase to resume partial image downloads.",
                    ],
                    quick_fix_command="podman pull docker.io/library/redis:7-alpine",
                ),
                PhaseIssue(
                    symptom="Port collision on 8080, 4000, 3000, or 5432",
                    root_cause="Another application on Mac is bound to one of the platform ports.",
                    fix_steps=[
                        "Check who is listening: `lsof -i :8080 -i :4000 -i :3000 -i :5432`",
                        "Stop conflicting local instances.",
                    ],
                    quick_fix_command="lsof -i :8080 -i :4000 -i :3000",
                ),
            ],
        ),
        PhaseDefinition(
            id="10-verify",
            name="End-to-End System Verification",
            script="10-verify.sh",
            description="Validates live HTTP/TCP health probes, latency, and database connectivity across all services.",
            category="Verification",
            requires_sudo=False,
            common_issues=[
                PhaseIssue(
                    symptom="One or more services reporting UNHEALTHY or CLOSED",
                    root_cause="Container is still initializing database schemas or crashed during startup.",
                    fix_steps=[
                        "Inspect failing container logs: `podman logs <service-name>`",
                        "Allow 15-30 seconds for initial database migrations (Langfuse/Postgres) to complete, then retry verification.",
                    ],
                    quick_fix_command="podman ps -a",
                ),
            ],
        ),
    ]
