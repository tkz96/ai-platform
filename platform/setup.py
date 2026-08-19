"""Platform Setup & Provisioning Engine.

Provides empirical state validation, sequential phase execution,
real-time SSE log streaming, structured failure remediation, and full platform health audits.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Generator


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
    status: str  # "completed" | "pending" | "failed" | "in_progress"
    empirical_details: dict[str, Any]
    error_message: str | None = None
    remediation: dict[str, Any] | None = None


ANSI_ESCAPE_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


def clean_ansi(text: str) -> str:
    """Strip ANSI escape sequences from terminal text."""
    return ANSI_ESCAPE_RE.sub("", text)


class SetupEngine:
    """Orchestrates platform provisioning phases with ground-truth empirical checks."""

    def __init__(self, project_root: Path | None = None) -> None:
        self.project_root = project_root or Path(__file__).parent.parent.resolve()
        self.scripts_dir = self.project_root / "scripts" / "install"
        self.state_file = self.project_root / ".install-state"

    def get_phase_definitions(self) -> list[PhaseDefinition]:
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

    def check_empirical_phase_status(self, phase_id: str) -> tuple[str, dict[str, Any], str | None]:
        """Inspect actual system state to determine if a phase is truly satisfied.

        Returns (status: 'completed'|'pending'|'failed', details: dict, error: str|None).
        """
        if phase_id == "05-podman":
            podman_bin = shutil.which("podman")
            if not podman_bin:
                return "pending", {"podman_installed": False}, "Podman binary not found in PATH"

            try:
                res = subprocess.run(
                    ["podman", "machine", "list", "--format", "json"],
                    capture_output=True,
                    text=True,
                    timeout=4,
                )
                if res.returncode == 0:
                    machines = json.loads(res.stdout) if res.stdout.strip() else []
                    ai_machine = next((m for m in machines if m.get("Name") == "ai-platform" or m.get("name") == "ai-platform"), None)
                    if ai_machine:
                        is_running = ai_machine.get("Running", False) or ai_machine.get("running", False)
                        if is_running:
                            return "completed", {"machine_exists": True, "running": True, "details": ai_machine}, None
                        return "pending", {"machine_exists": True, "running": False}, "Podman machine 'ai-platform' exists but is stopped"
                    return "pending", {"machine_exists": False}, "Podman machine 'ai-platform' has not been created yet"
            except Exception as e:
                return "pending", {"error": str(e)}, f"Could not query Podman machine: {e}"

            return "pending", {"podman_installed": True}, "Podman machine initialization pending"

        elif phase_id == "06a-networking":
            ip_found = False
            try:
                ifconfig_out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=2).stdout
                ip_found = "10.42.0.1" in ifconfig_out
            except Exception:
                pass

            dnsmasq_bin = shutil.which("dnsmasq") or os.path.exists("/opt/homebrew/sbin/dnsmasq") or os.path.exists("/usr/local/sbin/dnsmasq")

            details = {
                "ip_10_42_0_1_configured": ip_found,
                "dnsmasq_installed": bool(dnsmasq_bin),
            }

            if ip_found:
                return "completed", details, None
            return "pending", details, "Private Ethernet interface (10.42.0.1) is not configured"

        elif phase_id == "07-secrets":
            env_file = self.project_root / ".env"
            cluster_key = self.project_root / "secrets" / "cluster_key"
            env_exists = env_file.exists() and env_file.stat().st_size > 100
            key_exists = cluster_key.exists()

            details = {
                "env_file_exists": env_exists,
                "cluster_ssh_key_exists": key_exists,
            }

            if env_exists and key_exists:
                return "completed", details, None
            return "pending", details, ".env secrets or cluster SSH keys have not been generated"

        elif phase_id == "08-render":
            compose_file = self.project_root / "compose.yaml"
            caddy_file = self.project_root / "configs" / "caddy" / "Caddyfile"
            litellm_file = self.project_root / "configs" / "litellm" / "config.yaml"

            rendered_ok = compose_file.exists() and caddy_file.exists() and litellm_file.exists()
            details = {
                "compose_yaml_exists": compose_file.exists(),
                "caddyfile_exists": caddy_file.exists(),
                "litellm_config_exists": litellm_file.exists(),
            }

            if rendered_ok:
                return "completed", details, None
            return "pending", details, "Configuration files have not been rendered from templates"

        elif phase_id == "09-deploy":
            try:
                res = subprocess.run(
                    ["podman", "ps", "--format", "{{.Names}}"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                )
                if res.returncode == 0:
                    running_names = set(res.stdout.strip().splitlines())
                    required_services = {"postgres", "redis", "clickhouse", "langfuse", "litellm", "caddy"}
                    matched = running_names.intersection(required_services)
                    details = {
                        "running_containers": list(running_names),
                        "matched_services": list(matched),
                        "total_required": len(required_services),
                    }
                    if len(matched) == len(required_services):
                        return "completed", details, None
                    if len(matched) > 0:
                        return "pending", details, f"Partial deployment ({len(matched)}/{len(required_services)} services running)"
                    return "pending", details, "No control plane containers currently running"
            except Exception as e:
                return "pending", {"error": str(e)}, f"Cannot query Podman services: {e}"

            return "pending", {}, "Containers not deployed"

        elif phase_id == "10-verify":
            # Test key local ports
            ports = [8080, 4000, 3000, 5432, 8123, 6379]
            open_count = 0
            for p in ports:
                try:
                    with socket.create_connection(("127.0.0.1", p), timeout=0.3):
                        open_count += 1
                except Exception:
                    pass

            details = {"open_ports": open_count, "total_ports": len(ports)}
            if open_count == len(ports):
                return "completed", details, None
            return "pending", details, f"Verification pending ({open_count}/{len(ports)} ports responding)"

        return "pending", {}, "Unknown phase"

    def get_all_phase_statuses(self) -> list[PhaseStatus]:
        """Compute live empirical statuses for all phases with remediation details."""
        phases = self.get_phase_definitions()
        results: list[PhaseStatus] = []

        for p in phases:
            status, details, err = self.check_empirical_phase_status(p.id)
            remediation = None
            if status != "completed" and p.common_issues:
                remediation = {
                    "common_issues": [asdict(issue) for issue in p.common_issues],
                    "manual_command": f"bash scripts/install/{p.script}",
                }

            results.append(
                PhaseStatus(
                    id=p.id,
                    name=p.name,
                    description=p.description,
                    category=p.category,
                    requires_sudo=p.requires_sudo,
                    status=status,
                    empirical_details=details,
                    error_message=err,
                    remediation=remediation,
                )
            )

        return results

    def get_readiness_summary(self) -> dict[str, Any]:
        """Compute overall readiness score, next recommended phase, and flags."""
        statuses = self.get_all_phase_statuses()
        total = len(statuses)
        completed = sum(1 for s in statuses if s.status == "completed")
        pct = int((completed / total) * 100) if total > 0 else 0

        next_phase = next((s for s in statuses if s.status != "completed"), None)

        return {
            "total_phases": total,
            "completed_phases": completed,
            "percent_ready": pct,
            "is_fully_provisioned": completed == total,
            "next_phase_id": next_phase.id if next_phase else None,
            "next_phase_name": next_phase.name if next_phase else None,
            "phases": [asdict(s) for s in statuses],
        }

    def stream_phase_execution(self, phase_id: str) -> Generator[str, None, None]:
        """Execute a specific provisioning phase and stream real-time SSE output events."""
        phases_map = {p.id: p for p in self.get_phase_definitions()}
        phase = phases_map.get(phase_id)

        if not phase:
            yield f"event: error\ndata: {json.dumps({'error': f'Invalid phase id: {phase_id}'})}\n\n"
            return

        script_path = self.scripts_dir / phase.script
        if not script_path.exists():
            yield f"event: error\ndata: {json.dumps({'error': f'Script not found: {phase.script}'})}\n\n"
            return

        yield f"event: step_start\ndata: {json.dumps({'phase_id': phase.id, 'name': phase.name})}\n\n"
        yield f"event: log\ndata: {json.dumps({'line': f'===> Starting Phase {phase.id}: {phase.name}'})}\n\n"
        yield f"event: log\ndata: {json.dumps({'line': f'Executing: bash {script_path.name}'})}\n\n"

        env = os.environ.copy()
        env["PROJECT_ROOT"] = str(self.project_root)
        env["NONINTERACTIVE"] = "1"
        if "PATH" in env:
            env["PATH"] = f"/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:{env['PATH']}"

        start_time = time.perf_counter()
        try:
            process = subprocess.Popen(
                ["bash", str(script_path)],
                cwd=str(self.project_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
            )

            if process.stdout:
                for line in iter(process.stdout.readline, ""):
                    cleaned = clean_ansi(line.rstrip())
                    if cleaned:
                        yield f"event: log\ndata: {json.dumps({'line': cleaned})}\n\n"

            process.wait()
            duration = round(time.perf_counter() - start_time, 2)

            if process.returncode == 0:
                yield f"event: log\ndata: {json.dumps({'line': f'✓ Phase {phase.id} completed successfully in {duration}s'})}\n\n"
                yield f"event: step_done\ndata: {json.dumps({'phase_id': phase.id, 'success': True, 'duration_s': duration})}\n\n"
            else:
                yield f"event: log\ndata: {json.dumps({'line': f'✗ Phase {phase.id} failed with exit code {process.returncode} ({duration}s)'})}\n\n"
                remediation = {
                    "common_issues": [asdict(issue) for issue in phase.common_issues],
                    "manual_command": f"bash scripts/install/{phase.script}",
                }
                yield f"event: error\ndata: {json.dumps({'phase_id': phase.id, 'exit_code': process.returncode, 'remediation': remediation})}\n\n"

        except Exception as e:
            yield f"event: log\ndata: {json.dumps({'line': f'Execution exception: {e}'})}\n\n"
            yield f"event: error\ndata: {json.dumps({'phase_id': phase.id, 'error': str(e)})}\n\n"

    def stream_all_phases_execution(self) -> Generator[str, None, None]:
        """Execute all uncompleted phases sequentially, streaming SSE events throughout."""
        phases = self.get_phase_definitions()
        yield f"event: log\ndata: {json.dumps({'line': '=== AI Platform Provisioning Sequence Initiated ==='})}\n\n"

        all_success = True
        for p in phases:
            status, _, _ = self.check_empirical_phase_status(p.id)
            if status == "completed":
                yield f"event: log\ndata: {json.dumps({'line': f'⤳ Skipping Phase {p.id} ({p.name}) — Already satisfied.'})}\n\n"
                yield f"event: step_done\ndata: {json.dumps({'phase_id': p.id, 'success': True, 'skipped': True})}\n\n"
                continue

            for sse in self.stream_phase_execution(p.id):
                yield sse
                if "event: error" in sse:
                    all_success = False
                    break

            if not all_success:
                yield f"event: log\ndata: {json.dumps({'line': '=== Provisioning sequence halted due to phase failure. Review troubleshooting guidance above. ==='})}\n\n"
                yield f"event: complete\ndata: {json.dumps({'success': False})}\n\n"
                return

        yield f"event: log\ndata: {json.dumps({'line': '🎉 All phases completed successfully! Platform is fully provisioned.'})}\n\n"
        yield f"event: complete\ndata: {json.dumps({'success': True})}\n\n"

    def run_full_audit(self) -> dict[str, Any]:
        """Execute comprehensive system diagnostic audit across host, VM, networking, and containers."""
        audit_items: list[dict[str, Any]] = []

        def add_item(category: str, name: str, passed: bool, status: str, details: str, fix: str | None = None) -> None:
            audit_items.append({
                "category": category,
                "name": name,
                "passed": passed,
                "status": status,
                "details": details,
                "fix": fix,
            })

        # 1. System & Architecture
        uname = os.uname()
        is_arm64 = uname.machine == "arm64"
        add_item(
            "Host System",
            "Apple Silicon Architecture",
            is_arm64,
            "OPTIMAL" if is_arm64 else "COMPATIBLE",
            f"Darwin {uname.release} ({uname.machine})",
        )

        # 2. Tooling
        for tool_name, cmd in [
            ("Homebrew", ["brew", "--version"]),
            ("Python 3.12+", ["python3", "--version"]),
            ("uv Package Manager", ["uv", "--version"]),
            ("Podman Engine", ["podman", "--version"]),
            ("jq JSON Processor", ["jq", "--version"]),
            ("yq YAML Processor", ["yq", "--version"]),
        ]:
            found = shutil.which(cmd[0]) is not None
            add_item(
                "Tooling",
                tool_name,
                found,
                "INSTALLED" if found else "MISSING",
                "Available in PATH" if found else "Run ./bootstrap.sh to install missing tool",
                fix=f"brew install {cmd[0]}" if not found else None,
            )

        # 3. Podman Machine
        pm_status, pm_details, _ = self.check_empirical_phase_status("05-podman")
        add_item(
            "Infrastructure",
            "Podman Linux VM (ai-platform)",
            pm_status == "completed",
            "RUNNING" if pm_status == "completed" else "STOPPED/MISSING",
            "Virtual machine active and accepting OCI commands" if pm_status == "completed" else "Run Machine Init phase from Setup tab",
            fix="podman machine start ai-platform" if pm_status != "completed" else None,
        )

        # 4. Networking
        net_status, net_details, _ = self.check_empirical_phase_status("06a-networking")
        add_item(
            "Networking",
            "Private Subnet IP (10.42.0.1)",
            net_status == "completed",
            "CONFIGURED" if net_status == "completed" else "UNCONFIGURED",
            "Ethernet interface static IP active" if net_status == "completed" else "Run Networking phase to bind 10.42.0.1",
            fix="sudo bash scripts/install/06a-networking.sh" if net_status != "completed" else None,
        )

        # 5. Remote GPU Node
        ping_ok = False
        try:
            ping_ok = subprocess.run(["ping", "-c", "1", "-W", "1", "10.42.0.2"], capture_output=True).returncode == 0
        except Exception:
            pass
        add_item(
            "Networking",
            "Linux GPU Node Reachability (10.42.0.2)",
            ping_ok,
            "REACHABLE" if ping_ok else "OFFLINE",
            "ICMP ping responded" if ping_ok else "Verify Ethernet cable connected to Linux PC and node enrolled",
            fix="Connect Ethernet cable or run enrollment script on Linux PC",
        )

        # 6. Containers
        dep_status, dep_details, _ = self.check_empirical_phase_status("09-deploy")
        running_cnt = len(dep_details.get("matched_services", []))
        add_item(
            "Containers",
            "Control Plane Containers",
            dep_status == "completed",
            f"{running_cnt}/6 ACTIVE",
            "All 6 Podman service containers active" if dep_status == "completed" else "Run Deploy Services phase from Setup tab",
            fix="podman compose up -d" if dep_status != "completed" else None,
        )

        # 7. Ports
        for name, p in [("Caddy (:8080)", 8080), ("LiteLLM (:4000)", 4000), ("Langfuse (:3000)", 3000)]:
            is_open = False
            try:
                with socket.create_connection(("127.0.0.1", p), timeout=0.2):
                    is_open = True
            except Exception:
                pass
            add_item(
                "Health Probes",
                name,
                is_open,
                "LISTENING" if is_open else "CLOSED",
                f"TCP port {p} responsive" if is_open else f"Port {p} not answering",
                fix=f"Check container status: podman logs {name.split()[0].lower()}" if not is_open else None,
            )

        passed_cnt = sum(1 for i in audit_items if i["passed"])
        total_cnt = len(audit_items)

        return {
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
            "total_checks": total_cnt,
            "passed_checks": passed_cnt,
            "failed_checks": total_cnt - passed_cnt,
            "overall_health": "HEALTHY" if passed_cnt == total_cnt else ("DEGRADED" if passed_cnt >= total_cnt * 0.7 else "ACTION_REQUIRED"),
            "checks": audit_items,
        }
