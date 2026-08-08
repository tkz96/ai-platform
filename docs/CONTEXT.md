# Platform Context

This document describes the design principles, machine roles, and operational boundaries for the AI Platform.

## Core Philosophy

- **Declarative**: Configuration defines infrastructure. Python code renders it. Containers execute it.
- **Reproducible**: Deploying from scratch produces an identical environment.
- **Immutable**: Never modify running containers directly. Make changes in source templates and redeploy.
- **Isolated**: Inference workloads run on dedicated hardware, separate from control plane services.
- **Secure**: Default deny network policies. Secrets remain outside version control.
- **One-click**: A fresh Mac can be fully provisioned with `./bootstrap.sh`.

## Machine Roles

| Machine | Role | Hosted Services |
|---|---|---|
| Control Plane (Mac Mini) | Routing, observability, storage | Caddy, LiteLLM, Langfuse, PostgreSQL, ClickHouse, Redis |
| Inference Server | Token generation | llama.cpp, CUDA, GGUF models |
| Developer Machine | Client application | IDEs, AI coding agents, CLI tools |

### Control Plane
Runs all management services inside containers. Performs no model inference.

### Inference Server
Dedicated host for model inference. Runs no databases, dashboards, or routing logic.

### Developer Machine
Connects to LiteLLM through the OpenAI-compatible API endpoint. Hosts no infrastructure services.

## Repository Boundaries

### Included
- Platform configuration (`platform.yaml`, `versions.yaml`)
- Service manifests (`services/*.yaml`)
- Configuration templates (`templates/*.j2`)
- Python management tooling (`platform/`, `bootstrap.py`)
- Shell installer (`bootstrap.sh`, `scripts/install/`)
- Operations Makefile (`Makefile`)
- CI pipeline (`.github/workflows/`)
- Documentation (`docs/`)

### Excluded
- Model weight files
- Persistent database storage (`data/`)
- State and backups (`state/`, `backups/`)
- Application source code
- Generated files (`compose.yaml`, `configs/`)
- Secrets (`.env`, `secrets/`)
- Install state (`.install-state`)

## Installation Model

The platform uses a clean two-layer boundary:

| Layer | Entry Point | Responsibility |
|---|---|---|
| Machine preparation | `bootstrap.sh` | Install tools, init Podman, generate secrets, validate ports |
| Platform deployment | `bootstrap.py` | Validate config, render templates, deploy containers, verify health |

`bootstrap.sh` is a thin orchestrator that sources modular scripts from `scripts/install/`.
It prepares the machine, then delegates to `bootstrap.py` for platform operations.

## Guidelines for AI Coding Agents

Follow these rules when modifying this repository:

1. Edit source files only (`platform.yaml`, `versions.yaml`, `services/*.yaml`, `templates/*.j2`, `platform/`, `bootstrap.sh`, `scripts/install/`).
2. Never edit generated files (`compose.yaml`, `configs/*`, `.env`, `secrets/*`, `.install-state`).
3. Run `make lint` and `make test` before declaring completion.
4. Keep Python code modular and typed.
5. Use existing `make` targets or `./bootstrap.sh` subcommands instead of custom shell logic.
6. Keep `bootstrap.sh` as a thin orchestrator — put logic in `scripts/install/` modules.
7. Never hardcode secrets or ports — use `secrets/` and `.install-state` for configuration.