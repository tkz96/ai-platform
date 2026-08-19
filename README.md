# AI Platform

Self-hosted AI infrastructure with an explicit Control Plane (Mac Mini) + Inference Node (Linux PC) architecture over a dedicated private Ethernet link (`10.42.0.0/24`).

## Purpose

This repository provisions and manages a two-node AI platform with declarative YAML, automated rendering, and strict network safety.

- **Control Plane (Mac Mini)**: Runs request routing (Caddy), API gateway (LiteLLM), observability (Langfuse), and data storage (Postgres, ClickHouse, Redis) in rootless Podman containers. Acts as DHCP server, DNS forwarder, and NAT gateway for the inference subnet.
- **Inference Node (Linux PC)**: Runs high-performance model inference (`llama-server` / Qwen) on dedicated GPU hardware. All internet traffic routes through the Mac Mini via the private Ethernet link.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Mac Mini (Control Plane) — 10.42.0.1                   │
│                                                         │
│  ┌─────────┐ ┌──────────┐ ┌─────────┐ ┌─────────────┐  │
│  │ Caddy   │ │ LiteLLM  │ │Langfuse │ │ Postgres    │  │
│  │ :8080   │ │ :4000    │ │ :3000   │ │ ClickHouse  │  │
│  │ :8443   │ │          │ │         │ │ Redis       │  │
│  └─────────┘ └──────────┘ └─────────┘ └─────────────┘  │
│                                                         │
│  dnsmasq (DHCP+DNS) ─── PF NAT Gateway ─── en1 (WAN)   │
│                   en0 (Private Ethernet)                │
└──────────────────────┬──────────────────────────────────┘
                       │  10.42.0.0/24
                       │  Private Ethernet
┌──────────────────────┴──────────────────────────────────┐
│  Linux PC (Inference Node) — 10.42.0.2                  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │ llama-server :8080                               │   │
│  │ Qwen 3.6 35B-A3B  ·  NVIDIA RTX GPU             │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Features

- **Multi-Node Architecture**: Explicit separation of control plane services from GPU inference hardware.
- **Dedicated Private Network**: Point-to-point Ethernet link (`10.42.0.1` ↔ `10.42.0.2`) with dnsmasq DHCP, DNS forwarding, and macOS PF NAT gateway. Zero disruption to existing Internet/LAN connections.
- **Zero-Touch Linux Enrollment**: A single `curl | sudo bash` command on the Linux PC auto-configures networking (interface, default route, DNS, IPv4 APT), installs OpenSSH, discovers hardware (CPU, RAM, GPU), and registers with the Mac orchestrator.
- **Structured Diagnostics**: A shared `DiagnosticResult` contract (operation, command, exit code, stdout, stderr, detected state, recommendation, retryability) used by both CLI and the future Web UI. Automatic redaction of secrets, tokens, and SSH keys.
- **Shared Service Manager**: A strict-whitelist Python domain layer (`ServiceManager`) providing launch, stop, restart, health probe, log retrieval, and first-class diagnostics for all platform services.
- **Non-Blocking Offline Nodes**: 5-second SSH timeouts per node. Unreachable nodes are marked `offline` without blocking provisioning of healthy nodes. Registry state is saved incrementally.
- **Configuration-Driven**: YAML defines the platform. Python builds it. Jinja2 renders it.
- **Reproducible & Validated**: Multi-stage verification from host TCP to Podman VM and end-to-end model completion.
- **Rootless & Secure**: Uses rootless Podman with unprivileged ports (8080/8443) and local-only service exposure.

## Repository Layout

```
.
├── bootstrap.sh              # Fresh-machine entry point (shell)
├── bootstrap.py              # Platform CLI entry point (Python)
├── platform.yaml             # Platform configuration (source)
├── versions.yaml             # Service versions (source)
├── services/                 # Service manifests (source)
├── templates/                # Jinja2 templates (source)
├── ai_platform/              # Python domain layer
│   ├── diagnostics.py        #   DiagnosticResult contract & secret redaction
│   ├── service_manager.py    #   Shared ServiceManager (CLI + Web UI)
│   ├── setup/                #   Structured setup engine (phases, readiness, audit)
│   ├── web/                  #   FastAPI Web UI, routes, security, partials
│   ├── provisioner.py        #   SSH-based node provisioning with timeouts
│   ├── enrollment.py         #   HTTP enrollment server for Linux nodes
│   ├── nodes.py              #   Node registry data model
│   ├── probe.py              #   TCP/HTTP health probes
│   └── ...
├── scripts/
│   ├── install/              # Modular install phases (shell)
│   │   ├── lib/
│   │   │   ├── networking.sh #   dnsmasq, NAT, PID management
│   │   │   ├── diagnostics.sh#   Shell diagnostic rendering & redaction
│   │   │   ├── ui.sh         #   Terminal UI helpers
│   │   │   └── state.sh      #   Install state tracking
│   │   ├── 06a-networking.sh #   Network enrollment orchestration
│   │   └── ...
│   └── inference/
│       └── node-enroll.sh    # Zero-touch Linux enrollment script
├── tests/                    # Automated unit & integration tests (76 passing)
├── docs/                     # Architecture, operations, decisions
├── .github/workflows/        # CI pipeline
├── configs/                  # GENERATED — do not edit
├── compose.yaml              # GENERATED — do not edit
├── Makefile                  # Developer commands
└── pyproject.toml            # Python project metadata
```


> [!CAUTION]
> `compose.yaml` and `configs/` are **generated files**. Never edit them directly.
> Edit `platform.yaml`, `versions.yaml`, `services/*.yaml`, or `templates/` instead.

## Quick Start

### Prerequisites

**Mac Mini (Control Plane)**:
- macOS 14 (Sonoma) or newer
- Apple Silicon (M1, M2, M3, or M4)
- 60 GB free disk space, 8 GB memory
- One physical Ethernet port dedicated to the inference link

**Linux PC (Inference Node)**:
- Ubuntu 22.04 or 24.04 LTS
- NVIDIA GPU with drivers installed (optional, CPU mode supported)
- Physical Ethernet connection to the Mac Mini (direct or via switch)

### Installation

For a full step-by-step guide, see [docs/INSTALL.md](docs/INSTALL.md).

```bash
# On the Mac Mini
git clone git@github.com:tkz96/ai-platform.git
cd ai-platform
./bootstrap.sh
```

The installer will:

1. Check macOS prerequisites (version, architecture, disk, memory)
2. Install required tools (Homebrew, Python, uv, Podman, dnsmasq)
3. Initialize a Podman machine (4 CPUs, 8 GB RAM, 60 GB disk)
4. Generate secrets and create `.env`
5. Validate ports
6. Configure private Ethernet interface (`10.42.0.1/24`)
7. Start dnsmasq DHCP server and macOS PF NAT gateway
8. Launch enrollment HTTP server and display enrollment instructions
9. Render configuration and deploy services in dependency order
10. Verify health checks and print connection information

### Linux Node Enrollment

When the installer reaches Stage 5, it displays a one-time enrollment command. On each **fresh Linux inference PC**, run:

```bash
curl -fsSL http://10.42.0.1:8765/node-enroll.sh -o node-enroll.sh
chmod +x node-enroll.sh
sudo ./node-enroll.sh --token <TOKEN>
```

The enrollment script automatically:
- Detects and activates the physical Ethernet interface
- Configures default IPv4 route and DNS via the Mac Mini
- Forces APT to IPv4 mode (avoids IPv6 timeouts on private links)
- Installs and starts OpenSSH server
- Discovers hardware (CPU cores, RAM, GPU model/VRAM)
- Registers with the Mac orchestrator and receives a reserved IP
- Authorizes the Mac cluster SSH key for remote provisioning

## Commands

| Command | Action |
|---|---|
| `./bootstrap.sh` | Full installation on a fresh Mac |
| `./bootstrap.sh doctor` | Check machine readiness |
| `./bootstrap.sh status` | Check service health and inference node status |
| `./bootstrap.sh start` | Start platform services |
| `./bootstrap.sh stop` | Stop platform services |
| `./bootstrap.sh restart` | Restart platform services |
| `./bootstrap.sh connect-inference` | Run network enrollment flow (Stage 5+) |
| `./bootstrap.sh update` | Update platform (with review) |
| `./bootstrap.sh verify` | Run health checks |
| `./bootstrap.sh logs` | Tail service logs |
| `./bootstrap.sh backup` | Backup databases and state |
| `./bootstrap.sh restore --src <path>` | Restore from backup |
| `./bootstrap.sh destroy` | Remove all containers, networks, and volumes |

## Platform Domain Layer

### DiagnosticResult

A structured contract for all diagnostic output, shared between CLI and the future Web UI:

```python
DiagnosticResult(
    operation="diagnose:dnsmasq",
    command="sudo lsof -nP -iUDP:67",
    exit_code=0,
    stdout="dnsmasq PID: 12345",
    stderr="",
    detected_state={"pid": "12345", "udp_67_owner": "dnsmasq"},
    recommendation="DHCP server operating normally",
    is_retryable=False,
)
```

Automatic redaction strips enrollment tokens, API keys, SSH private keys, database passwords, and connection URIs from all diagnostic output.

### ServiceManager

A strict-whitelist domain layer for platform service lifecycle:

- **Allowed services**: `postgres`, `redis`, `clickhouse`, `langfuse`, `litellm`, `caddy`, `podman`
- **Operations**: `launch_service`, `stop_service`, `restart_service`, `get_logs`, `diagnose_service`
- **Launch status**: `STARTED+HEALTHY`, `STARTED+UNHEALTHY`, `FAILED_TO_START`
- **Diagnostics**: First-class support for `dnsmasq`, `podman`, `llama-server`, `ssh`, and all container services

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
make test    # Pytest suite (52 tests)
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