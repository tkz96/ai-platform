# AI Platform

> A reproducible, self-hosted AI infrastructure platform for running inference, routing requests, observability, and future AI services.

---

# Overview

This repository provisions and manages a self-hosted AI platform.

The project is designed around several guiding principles:

- Infrastructure as Code
- Reproducibility
- Minimal manual configuration
- Idempotent deployments
- Separation of configuration from implementation
- Official upstream images whenever possible
- GitOps workflow
- Local-first development
- Long-term maintainability

The objective is that a fresh machine should be able to become a fully functioning AI server by cloning this repository and running a single bootstrap command.

---

# High Level Architecture

```text
                Developers
        ┌─────────────────────┐
        │ VS Code             │
        │ Antigravity         │
        │ Claude             │
        │ OpenHands          │
        └─────────┬───────────┘
                  │
                  ▼

        ┌─────────────────────────┐
        │      Mac Mini           │
        │-------------------------│
        │ LiteLLM                 │
        │ Langfuse                │
        │ Caddy                   │
        │ PostgreSQL              │
        │ Redis                   │
        │ ClickHouse              │
        │ Future Services         │
        └─────────┬───────────────┘
                  │
                  ▼

        ┌─────────────────────────┐
        │   Inference Machine      │
        │-------------------------│
        │ llama.cpp               │
        │ Qwen                    │
        │ Future Models           │
        └─────────────────────────┘
```

---

# Design Principles

This repository follows a few non-negotiable rules.

## Single Responsibility

Each machine performs one job.

Examples:

- inference
- routing
- observability
- development

---

## Immutable Infrastructure

Machines should never be manually configured.

All changes must originate from this repository.

---

## Configuration Driven

Behavior belongs inside YAML.

Logic belongs inside Python.

Templates belong inside `templates/`.

---

## Reproducibility

Any developer should be able to execute

```bash
git clone ...
uv sync
uv run python bootstrap.py install
```

and obtain the exact same platform.

---

# Repository Structure

```
.
├── bootstrap.py
├── platform/
├── services/
├── templates/
├── configs/
├── docs/
├── tests/
├── scripts/
├── data/
├── backups/
├── state/
├── versions.yaml
├── platform.yaml
└── pyproject.toml
```

---

# Directory Responsibilities

## platform/

Python source code.

Contains:

- CLI
- configuration loading
- validation
- rendering
- orchestration
- service abstractions

---

## templates/

Jinja templates used to generate configuration files.

Generated files should **never** be edited manually.

---

## configs/

Service configuration.

Examples:

- LiteLLM
- Caddy
- Langfuse

---

## services/

Defines each deployable service.

Each service has its own manifest.

---

## docs/

Project documentation.

Architecture decisions belong here.

---

## tests/

Automated tests.

---

## data/

Persistent volumes.

Ignored by Git.

---

## backups/

Generated backups.

Ignored by Git.

---

# Technology Stack

| Component | Purpose |
|------------|----------|
| Python | Platform automation |
| uv | Dependency management |
| Podman | Containers |
| Podman Compose | Orchestration |
| LiteLLM | AI routing |
| Langfuse | Observability |
| PostgreSQL | Metadata |
| Redis | Cache |
| ClickHouse | Analytics |
| Caddy | Reverse proxy |
| GitHub Actions | CI/CD |

---

# Development Workflow

Feature branches only.

```
feature/*
```

↓

Open Pull Request

↓

CI passes

↓

Merge into main

↓

Deploy

---

# Local Development

Clone

```bash
git clone git@github.com:<user>/ai-platform.git
```

Install dependencies

```bash
uv sync
```

Run checks

```bash
uv run ruff check .
uv run ruff format .
uv run yamllint .
uv run pytest
```

---

# Bootstrap Commands

Eventually all platform management should happen through

```bash
uv run python bootstrap.py
```

Planned commands

```text
install
update
verify
backup
restore
status
render
generate
destroy
```

---

# Coding Standards

Python

- Ruff
- Type hints
- Small functions
- No duplicated logic

YAML

- yamllint
- Two-space indentation

Templates

- Pure Jinja
- No business logic

---

# Version Management

Service versions are defined in

```
versions.yaml
```

The code should never hardcode versions.

---

# Configuration

Platform configuration is defined in

```
platform.yaml
```

The platform should be configurable without modifying Python code.

---

# CI

Every commit should validate

- Ruff
- Formatting
- YAML
- Tests
- Template rendering
- Configuration schema

Deployment should only occur after successful validation.

---

# Backup Strategy

Persistent services should support automated backup.

Initially

- PostgreSQL
- ClickHouse

Later

- Redis snapshots
- LiteLLM configuration
- Langfuse metadata

---

# Security Goals

- No secrets committed
- SSH key authentication
- Principle of least privilege
- Official container images
- Configuration validation before deployment

---

# Roadmap

## Phase 1

- Repository
- Bootstrap framework
- Configuration rendering

## Phase 2

- LiteLLM
- Langfuse
- Caddy

## Phase 3

- GitHub Actions
- Automatic deployment

## Phase 4

- Monitoring
- Backups
- Rollbacks

## Phase 5

- Kubernetes (optional)

---

# Contributing

1. Create feature branch
2. Make changes
3. Run validation
4. Submit Pull Request

---

# License

Specify project license here.

---

# Acknowledgements

This project intentionally builds on official upstream projects whenever possible.

- LiteLLM
- Langfuse
- Podman
- llama.cpp
- PostgreSQL
- Redis
- ClickHouse
- Caddy