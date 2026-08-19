"""Platform Setup Engine orchestrator."""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from collections.abc import Generator
from dataclasses import asdict
from pathlib import Path
from typing import Any

from ai_platform.setup.audit import run_full_audit
from ai_platform.setup.phases import (
    PhaseDefinition,
    PhaseStatus,
    get_canonical_phase_definitions,
)
from ai_platform.setup.readiness import check_empirical_phase_status

ANSI_ESCAPE_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
_SETUP_LOCK = threading.Lock()


def clean_ansi(text: str) -> str:
    """Strip ANSI escape sequences from terminal text."""
    return ANSI_ESCAPE_RE.sub("", text)


class SetupEngine:
    """Orchestrates platform provisioning phases with ground-truth empirical checks and lock control."""

    def __init__(self, project_root: Path | None = None) -> None:
        self.project_root = project_root or Path(__file__).parent.parent.parent.resolve()
        self.scripts_dir = self.project_root / "scripts" / "install"
        self.state_file = self.project_root / ".install-state"

    def get_phase_definitions(self) -> list[PhaseDefinition]:
        """Return the canonical ordered list of dashboard provisioning phases."""
        return get_canonical_phase_definitions()

    def check_empirical_phase_status(self, phase_id: str) -> tuple[str, dict[str, Any], str | None]:
        """Determine empirical status of a phase."""
        return check_empirical_phase_status(phase_id, self.project_root)

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
        if not _SETUP_LOCK.acquire(blocking=False):
            yield f"event: error\ndata: {json.dumps({'error': 'Another setup execution is currently in progress.'})}\n\n"
            return

        try:
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
                env["PATH"] = (
                    f"/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:{env['PATH']}"
                )

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
        finally:
            _SETUP_LOCK.release()

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
        return run_full_audit(self.project_root)
