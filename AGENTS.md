# AI Platform — Agent Guidelines

This repository contains the infrastructure for self-hosted AI services.

## Core Architectural Rules

1. **Generated vs Source Files**:
   - `compose.yaml` and `configs/` are **GENERATED** artifacts. NEVER edit them directly.
   - Declarative source files belong in `platform.yaml`, `versions.yaml`, `services/*.yaml`, and `templates/*.j2`.
   - All infrastructure changes MUST originate from source templates and configuration manifests.

2. **Configuration-Driven Architecture**:
   - YAML describes **what** the platform should be.
   - Python (`platform/`) determines **how** it is built.
   - Jinja2 (`templates/`) defines **how configuration is rendered**.
   - Containers execute the resulting infrastructure.

3. **Validation & Rendering Flow**:
   - Always run validation and rendering through `uv run python bootstrap.py render`.
   - Never commit generated files or secrets (`.env`, `data/`, `backups/`).

4. **Service Abstractions**:
   - Declarative service manifests live in `services/*.yaml`.
   - Never hardcode service names or single-purpose logic in CLI commands.

5. **Code Standards**:
   - Run `make lint` and `make test` before declaring success on any change.
   - Python code must pass `ruff` linting and formatting rules.
   - YAML files must pass `yamllint`.
