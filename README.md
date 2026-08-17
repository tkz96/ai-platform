# AI Platform

Self-hosted AI infrastructure with an explicit Control Plane (Mac Mini) + Inference Node (Linux PC) architecture over a dedicated private Ethernet link (`10.42.0.0/24`).

## Purpose

This repository provisions and manages a two-node AI platform with declarative YAML, automated rendering, and strict network safety.

- **Control Plane (Mac Mini)**: Runs request routing (Caddy), API gateway (LiteLLM), observability (Langfuse), and data storage (Postgres, ClickHouse, Redis) in rootless Podman containers.
- **Inference Node (Linux PC)**: Runs high-performance model inference (`llama-server` / Qwen) on dedicated GPU hardware.

## Features

- **Multi-Node Architecture**: Explicit separation of control plane services from GPU inference hardware.
- **Dedicated Private Network**: Point-to-point Ethernet link (`10.42.0.1` ↔ `10.42.0.2`) with zero disruption to existing Internet/LAN connections.
- **Configuration-Driven**: YAML defines the platform. Python builds it. Jinja2 renders it.
- **Reproducible & Validated**: Multi-stage verification from host TCP to Podman VM and end-to-end model completion.
- **Rootless & Secure**: Uses rootless Podman with unprivileged ports (8080/8443) and local-only service exposure.

## Repository Layout

```
.
├── bootstrap.sh            # Fresh-machine entry point (shell)
├── bootstrap.py             # Platform CLI entry point (Python)
├── platform.yaml            # Platform configuration (source)
├── versions.yaml            # Service versions (source)
├── services/                # Service manifests (source)
├── templates/               # Jinja2 templates (source)
├── platform/                # Python CLI and rendering logic
├── scripts/install/         # Modular install phases (shell)
├── tests/                   # Automated tests
├── docs/                    # Architecture, operations, decisions
├── .github/workflows/       # CI pipeline
├── configs/                 # GENERATED — do not edit
├── compose.yaml             # GENERATED — do not edit
├── Makefile                 # Developer commands
└── pyproject.toml           # Python project metadata
```

> [!CAUTION]
> `compose.yaml` and `configs/` are **generated files**. Never edit them directly.
> Edit `platform.yaml`, `versions.yaml`, `services/*.yaml`, or `templates/` instead.

## Quick Start

For a full step-by-step guide, see [docs/INSTALL.md](docs/INSTALL.md).

```bash
git clone git@github.com:tkz96/ai-platform.git
cd ai-platform
./bootstrap.sh
```

The installer will:

1. Check your Mac
2. Install required tools (Homebrew, Python, uv, Podman)
3. Initialize a Podman machine (4 CPUs, 8 GB RAM, 60 GB disk)
4. Generate secrets and create `.env`
5. Validate ports
6. Render configuration
7. Pull pinned container images
8. Start services in dependency order
9. Verify health checks
10. Print connection information

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon (M1, M2, M3, or M4)
- 60 GB free disk space
- 8 GB memory

The installer handles all software installation automatically.

## Commands

| Command | Action |
|---|---|
| `./bootstrap.sh` | Full installation on a fresh Mac |
| `./bootstrap.sh doctor` | Check machine readiness |
| `./bootstrap.sh start` | Start platform services |
| `./bootstrap.sh stop` | Stop platform services |
| `./bootstrap.sh restart` | Restart platform services |
| `./bootstrap.sh status` | Check service health |
| `./bootstrap.sh update` | Update platform (with review) |
| `./bootstrap.sh verify` | Run health checks |
| `./bootstrap.sh logs` | Tail service logs |
| `./bootstrap.sh backup` | Backup databases and state |
| `./bootstrap.sh restore --src <path>` | Restore from backup |
| `./bootstrap.sh destroy` | Remove all containers, networks, and volumes |

## Daily Development

### Make a change

1. Create a feature branch.
2. Edit source files (`platform.yaml`, `versions.yaml`, `services/*.yaml`, `templates/`).
3. Render and validate.
4. Commit and open a pull request.

### Developer commands (Makefile)

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

## CI

GitHub Actions runs on every push and pull request:

1. **Lint and Test** (Ubuntu) — ruff, yamllint, pytest
2. **macOS Deployment Test** — full Podman deployment with health checks

## Documentation

| Document | Contents |
|---|---|
| [INSTALL.md](docs/INSTALL.md) | Step-by-step installation guide |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, service topology, data flow |
| [OPERATIONS.md](docs/OPERATIONS.md) | Deployment, backup, restore, monitoring |
| [DECISIONS.md](docs/DECISIONS.md) | Architecture decision records |
| [ROADMAP.md](docs/ROADMAP.md) | Planned work and milestones |
| [AGENTS.md](AGENTS.md) | Rules for AI coding agents |

## License

[MIT](LICENSE)