from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path
from typing import Any

from platform.config import resolve_platform
from platform.diagnostics import DiagnosticResult
from platform.probe import probe_http, probe_tcp
from platform.runner import ComposeRunner

ALLOWED_SERVICES = {
    "postgres",
    "redis",
    "clickhouse",
    "langfuse",
    "litellm",
    "caddy",
    "podman",
}


class ServiceManager:
    """Centralized Python domain manager for platform services.
    Enforces a strict service registry whitelist and handles lifecycle operations,
    health probes, log tailing, and first-class diagnostics.
    """

    def __init__(self, root_dir: Path, runner: ComposeRunner | None = None) -> None:
        self.root_dir = root_dir
        self.runner = runner or ComposeRunner()

    def _validate_service_name(self, name: str) -> None:
        if name not in ALLOWED_SERVICES:
            raise ValueError(
                f"Invalid or unauthorized service name: '{name}'. "
                f"Allowed services are: {sorted(list(ALLOWED_SERVICES))}"
            )

    def list_services(self) -> list[dict[str, Any]]:
        """Return live status of all whitelisted platform services."""
        resolved = resolve_platform(self.root_dir)
        results: list[dict[str, Any]] = []

        for name in resolved.dependency_order:
            manifest = resolved.services.get(name)
            port = manifest.ports[0].host_port if manifest and manifest.ports else None
            endpoint = f"http://localhost:{port}" if port else "N/A"

            probe_passed = False
            probe_status = "STOPPED"

            if port:
                if manifest and manifest.health and manifest.health.endpoint:
                    health_url = f"http://localhost:{port}{manifest.health.endpoint}"
                    h_res = probe_http(health_url, timeout=2)
                    probe_passed = h_res.passed
                    probe_status = "HEALTHY" if probe_passed else f"UNHEALTHY ({h_res.status})"
                else:
                    t_res = probe_tcp("localhost", port, timeout=2)
                    probe_passed = t_res.passed
                    probe_status = "HEALTHY" if probe_passed else f"UNHEALTHY ({t_res.status})"

            results.append(
                {
                    "name": name,
                    "endpoint": endpoint,
                    "status": probe_status,
                    "passed": probe_passed,
                }
            )

        return results

    def launch_service(self, name: str, timeout: int = 30) -> DiagnosticResult:
        """Launch a service, wait for health probe, and return final status.
        Result status can be STARTED+HEALTHY, STARTED+UNHEALTHY, or FAILED_TO_START.
        """
        self._validate_service_name(name)

        if name == "podman":
            cmd = ["podman", "machine", "start"]
            res = subprocess.run(cmd, capture_output=True, text=True)
            return DiagnosticResult(
                operation="launch_service:podman",
                command=" ".join(cmd),
                exit_code=res.returncode,
                stdout=res.stdout,
                stderr=res.stderr,
                detected_state={"status": "STARTED+HEALTHY" if res.returncode == 0 else "FAILED_TO_START"},
                recommendation="Check podman machine status using 'podman machine list'" if res.returncode != 0 else "",
            ).redact()

        # Compose service launch
        cmd_str = f"podman compose up -d {name}"
        try:
            compose_cmd = self.runner.get_compose_cmd() + ["up", "-d", name]
            subprocess.run(compose_cmd, cwd=self.root_dir, check=True, capture_output=True, text=True)
        except Exception as e:
            return DiagnosticResult(
                operation=f"launch_service:{name}",
                command=cmd_str,
                exit_code=1,
                stderr=str(e),
                detected_state={"status": "FAILED_TO_START"},
                recommendation=f"Check service logs for {name} using ./bootstrap.sh logs {name}",
                is_retryable=True,
            ).redact()

        # Poll health probe
        resolved = resolve_platform(self.root_dir)
        manifest = resolved.services.get(name)
        port = manifest.ports[0].host_port if manifest and manifest.ports else None

        if not port:
            return DiagnosticResult(
                operation=f"launch_service:{name}",
                command=cmd_str,
                exit_code=0,
                detected_state={"status": "STARTED+HEALTHY", "probe": "No ports exposed"},
            ).redact()

        health_url = f"http://localhost:{port}"
        if manifest and manifest.health and manifest.health.endpoint:
            health_url += manifest.health.endpoint

        start_time = time.time()
        healthy = False
        last_status = "pending"

        while time.time() - start_time < timeout:
            if manifest and manifest.health and manifest.health.endpoint:
                probe = probe_http(health_url, timeout=2)
                healthy = probe.passed
                last_status = probe.status
            else:
                probe = probe_tcp("localhost", port, timeout=2)
                healthy = probe.passed
                last_status = probe.status

            if healthy:
                break
            time.sleep(1)

        final_status = "STARTED+HEALTHY" if healthy else "STARTED+UNHEALTHY"
        return DiagnosticResult(
            operation=f"launch_service:{name}",
            command=cmd_str,
            exit_code=0 if healthy else 1,
            stdout=f"Service {name} deployed. Probe status: {last_status}",
            detected_state={"status": final_status, "endpoint": health_url, "probe_passed": healthy},
            recommendation=f"Check logs if UNHEALTHY: ./bootstrap.sh logs {name}" if not healthy else "",
            is_retryable=not healthy,
        ).redact()

    def stop_service(self, name: str) -> DiagnosticResult:
        """Stop a specific platform service."""
        self._validate_service_name(name)
        cmd = self.runner.get_compose_cmd() + ["stop", name]
        try:
            subprocess.run(cmd, cwd=self.root_dir, check=True, capture_output=True, text=True)
            return DiagnosticResult(
                operation=f"stop_service:{name}",
                command=" ".join(cmd),
                exit_code=0,
                detected_state={"status": "STOPPED"},
            ).redact()
        except Exception as e:
            return DiagnosticResult(
                operation=f"stop_service:{name}",
                command=" ".join(cmd),
                exit_code=1,
                stderr=str(e),
                detected_state={"status": "STOP_FAILED"},
            ).redact()

    def restart_service(self, name: str) -> DiagnosticResult:
        """Restart a specific platform service."""
        self._validate_service_name(name)
        self.stop_service(name)
        return self.launch_service(name)

    def get_logs(self, name: str, tail: int = 100) -> str:
        """Retrieve recent container logs for a service."""
        self._validate_service_name(name)
        try:
            cmd = self.runner.get_compose_cmd() + ["logs", f"--tail={tail}", name]
            proc = subprocess.run(
                cmd,
                cwd=self.root_dir,
                capture_output=True,
                text=True,
                timeout=10,
            )
            return proc.stdout or proc.stderr or "No log output recorded."
        except Exception as e:
            return f"Failed to retrieve logs for {name}: {e}"

    def get_endpoint(self, name: str) -> str | None:
        """Get endpoint URL for a given service if configured."""
        self._validate_service_name(name)
        resolved = resolve_platform(self.root_dir)
        manifest = resolved.services.get(name)
        if manifest and manifest.ports:
            port = manifest.ports[0].host_port
            return f"http://localhost:{port}"
        return None

    def diagnose_service(self, name: str) -> DiagnosticResult:
        """Run deep empirical diagnostic checks on any named system component or container."""
        if name not in ALLOWED_SERVICES and name not in ("dnsmasq", "llama-server", "ssh"):
            raise ValueError(f"Unknown diagnostic target: '{name}'")

        if name == "dnsmasq":
            pid_file = Path("/tmp/ai-platform-dnsmasq.pid")
            conf_file = self.root_dir / "state" / "dnsmasq.conf"
            pid_exists = pid_file.exists()
            pid_val = pid_file.read_text().strip() if pid_exists else None

            lsof_proc = subprocess.run(
                ["sudo", "lsof", "-nP", "-iUDP:67"], capture_output=True, text=True
            )
            udp_67_owner = lsof_proc.stdout.strip() or "none"

            pf_proc = subprocess.run(
                ["sudo", "pfctl", "-a", "ai_platform_nat", "-sn"], capture_output=True, text=True
            )
            pf_state = pf_proc.stdout.strip() or "inactive"

            is_ok = pid_exists and "dnsmasq" in udp_67_owner
            return DiagnosticResult(
                operation="diagnose:dnsmasq",
                command="sudo lsof -nP -iUDP:67; sudo pfctl -a ai_platform_nat -sn",
                exit_code=0 if is_ok else 1,
                stdout=f"dnsmasq PID: {pid_val}, PF NAT: {pf_state}",
                stderr="",
                detected_state={
                    "pid_file": str(pid_file),
                    "pid": pid_val,
                    "config_path": str(conf_file),
                    "udp_67_owner": udp_67_owner,
                    "pf_nat_rules": pf_state,
                },
                recommendation="Run ./bootstrap.sh connect-inference to restart DHCP server" if not is_ok else "DHCP server & NAT gateway operating normally",
                is_retryable=not is_ok,
            ).redact()

        if name == "podman":
            info_proc = subprocess.run(["podman", "info"], capture_output=True, text=True)
            mach_proc = subprocess.run(
                ["podman", "machine", "list"], capture_output=True, text=True
            )
            is_ok = info_proc.returncode == 0
            return DiagnosticResult(
                operation="diagnose:podman",
                command="podman info",
                exit_code=info_proc.returncode,
                stdout=mach_proc.stdout,
                stderr=info_proc.stderr,
                detected_state={
                    "podman_responsive": is_ok,
                    "machine_list": mach_proc.stdout.strip(),
                },
                recommendation="Run 'podman machine start' to initialize VM" if not is_ok else "Podman machine active",
                is_retryable=not is_ok,
            ).redact()

        # Default container diagnosis
        self._validate_service_name(name)
        logs = self.get_logs(name, tail=30)
        endpoint = self.get_endpoint(name)
        healthy = False
        if endpoint:
            probe = probe_http(endpoint, timeout=3)
            healthy = probe.passed

        return DiagnosticResult(
            operation=f"diagnose:{name}",
            command=f"podman compose logs --tail=30 {name}",
            exit_code=0 if healthy else 1,
            stdout=f"Service {name} endpoint: {endpoint}",
            stderr=logs,
            detected_state={"endpoint": endpoint, "is_healthy": healthy},
            recommendation=f"Service {name} is operating normally" if healthy else f"Restart container using ./bootstrap.sh restart {name}",
            is_retryable=not healthy,
        ).redact()
