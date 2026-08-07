# Platform Context

This document describes the design principles, machine roles, and operational boundaries for the AI Platform.

## Core Philosophy

- **Declarative**: Configuration defines infrastructure. Python code renders it. Containers execute it.
- **Reproducible**: Deploying from scratch produces an identical environment.
- **Immutable**: Never modify running containers directly. Make changes in source templates and redeploy.
- **Isolated**: Inference workloads run on dedicated hardware, separate from control plane services.
- **Secure**: Default deny network policies. Secrets remain outside version control.

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
- Operations Makefile (`Makefile`)
- Documentation (`docs/`)

### Excluded
- Model weight files
- Persistent database storage (`data/`)
- State and backups (`state/`, `backups/`)
- Application source code
- Generated files (`compose.yaml`, `configs/`)

## Guidelines for AI Coding Agents

Follow these rules when modifying this repository:

1. Edit source files only (`platform.yaml`, `versions.yaml`, `services/*.yaml`, `templates/*.j2`, `platform/`).
2. Never edit generated files (`compose.yaml`, `configs/*`).
3. Run `make lint` and `make test` before declaring completion.
4. Keep Python code modular and typed.
5. Use existing `make` targets instead of custom shell logic.