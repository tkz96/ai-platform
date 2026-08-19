# AI Platform — Agent Guidelines

This repository contains the infrastructure for self-hosted AI services.

## Core Architectural Rules

1. **Generated vs Source Files**:
   - `compose.yaml`, `configs/`, `.env`, `secrets/`, and `.install-state` are **GENERATED** artifacts. NEVER edit them directly.
   - Declarative source files belong in `platform.yaml`, `versions.yaml`, `services/*.yaml`, and `templates/*.j2`.
   - Shell installer logic belongs in `bootstrap.sh` and `scripts/install/*.sh`.
   - Python platform logic belongs in `ai_platform/` and `bootstrap.py`.
   - All infrastructure changes MUST originate from source templates and configuration manifests.

2. **Two-Layer Installation Model**:
   - `bootstrap.sh` — "Prepare this Mac." Installs tools, inits Podman, generates secrets, validates ports.
   - `bootstrap.py` — "Deploy this platform." Validates config, renders templates, deploys containers, verifies health.
   - Keep `bootstrap.sh` as a thin orchestrator. Put logic in `scripts/install/` modules.

3. **Configuration-Driven Architecture**:
   - YAML describes **what** the platform should be.
   - Python (`ai_platform/`) determines **how** it is built.

   - Jinja2 (`templates/`) defines **how configuration is rendered**.
   - Containers execute the resulting infrastructure.

4. **Validation & Rendering Flow**:
   - Always run validation and rendering through `uv run python bootstrap.py render`.
   - Never commit generated files or secrets (`.env`, `data/`, `backups/`, `secrets/`, `.install-state`).

5. **Service Abstractions**:
   - Declarative service manifests live in `services/*.yaml`.
   - Never hardcode service names or single-purpose logic in CLI commands.

6. **Code Standards**:
   - Run `make lint` and `make test` before declaring success on any change.
   - Python code must pass `ruff` linting and formatting rules.
   - YAML files must pass `yamllint`.
   - Shell scripts must use `set -euo pipefail` and be modular.