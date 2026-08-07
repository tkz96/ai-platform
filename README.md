# AI Platform

Self-hosted AI infrastructure. Runs inference, request routing, and observability as containers on a single machine.

## Purpose

This repository provisions and manages an AI platform with one command.

It replaces manual server configuration with declarative YAML and automated rendering.

## Features

- **Configuration-driven**: YAML defines the platform. Python builds it. Jinja2 renders it.
- **Reproducible**: Clone, install, deploy. Every run produces the same result.
- **Single command**: `make install` deploys the full stack.

## Repository Layout

```
.
├── platform.yaml          # Platform configuration (source)
├── versions.yaml          # Service versions (source)
├── services/              # Service manifests (source)
├── templates/             # Jinja2 templates (source)
├── platform/              # Python CLI and rendering logic
├── tests/                 # Automated tests
├── docs/                  # Architecture, operations, decisions
├── configs/               # GENERATED — do not edit
├── compose.yaml           # GENERATED — do not edit
├── bootstrap.py           # CLI entry point
├── Makefile               # Developer commands
└── pyproject.toml         # Python project metadata
```

> [!CAUTION]
> `compose.yaml` and `configs/` are **generated files**. Never edit them directly.
> Edit `platform.yaml`, `versions.yaml`, `services/*.yaml`, or `templates/` instead.

## Requirements

- Python ≥ 3.12
- [uv](https://docs.astral.sh/uv/)
- [Podman](https://podman.io/) with Podman Compose

## Quick Start

### 1. Clone the repository

```bash
git clone git@github.com:<user>/ai-platform.git
cd ai-platform
```

### 2. Install Python dependencies

```bash
uv sync
```

### 3. Create the environment file

```bash
cp .env.example .env
```

Edit `.env` and replace all placeholder values with real credentials.

### 4. Render configuration

```bash
make render
```

This validates `platform.yaml` and generates `compose.yaml` and `configs/`.

### 5. Deploy

```bash
make install
```

### 6. Verify

```bash
make status
```

## Daily Development

### Make a change

1. Create a feature branch.
2. Edit source files (`platform.yaml`, `versions.yaml`, `services/*.yaml`, `templates/`).
3. Render and validate.
4. Commit and open a pull request.

### Useful commands

| Command | Action |
|---|---|
| `make render` | Validate configuration and render templates |
| `make install` | Render and deploy containers |
| `make status` | Check service health |
| `make verify` | Validate schema and run health checks |
| `make update` | Pull latest images and redeploy |
| `make backup` | Backup databases and state |
| `make restore` | Restore from backup |
| `make destroy` | Remove all containers, networks, and volumes |

## Validation

Run these checks before every commit:

```bash
make lint    # Ruff lint + format check + yamllint
make test    # Pytest suite
```

Or run both:

```bash
make lint && make test
```

### Pre-commit checklist

- [ ] `make lint` passes
- [ ] `make test` passes
- [ ] `make render` succeeds
- [ ] No secrets in committed files

## Deployment

`make install` renders configuration and starts all containers with Podman Compose.

For operations procedures, see [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Documentation

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, service topology, data flow |
| [OPERATIONS.md](docs/OPERATIONS.md) | Deployment, backup, restore, monitoring |
| [DECISIONS.md](docs/DECISIONS.md) | Architecture decision records |
| [ROADMAP.md](docs/ROADMAP.md) | Planned work and milestones |
| [AGENTS.md](AGENTS.md) | Rules for AI coding agents |

## License

[MIT](LICENSE)