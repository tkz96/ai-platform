# How to Install the AI Platform

## Requirements

- A Mac with Apple Silicon (M1, M2, M3, or M4)
- macOS 14 (Sonoma) or newer
- At least 60 GB of free disk space
- At least 8 GB of memory (RAM)
- An internet connection

## Steps

1. Clone the repository:

   ```bash
   git clone git@github.com:tkz96/ai-platform.git
   cd ai-platform
   ```

2. Run the installer:

   ```bash
   ./bootstrap.sh
   ```

3. Answer the prompts. The installer will:
   - Check your Mac
   - Install missing tools (Homebrew, Python, uv, Podman)
   - Set up a Podman machine (4 CPUs, 8 GB RAM, 60 GB disk)
   - Generate secure passwords and keys
   - Validate ports
   - Start all services
   - Verify health checks

4. When the installer finishes, check that everything works:

   ```bash
   ./bootstrap.sh status
   ```

   All services should show as HEALTHY.

## Access the Platform

Open your web browser and go to:

- **Langfuse** (tracking): `http://localhost:3000`
- **LiteLLM** (API): `http://localhost:4000`
- **Caddy** (proxy): `http://localhost:8080`

## Commands

| Command | What it does |
|---|---|
| `./bootstrap.sh status` | Check if services are healthy |
| `./bootstrap.sh logs` | See what the services are doing |
| `./bootstrap.sh stop` | Stop all services |
| `./bootstrap.sh start` | Start all services again |
| `./bootstrap.sh restart` | Stop and start all services |
| `./bootstrap.sh doctor` | Check if your Mac is ready |
| `./bootstrap.sh update` | Update the platform to a new version |
| `./bootstrap.sh backup` | Save a backup of your data |
| `./bootstrap.sh destroy` | Remove everything (be careful!) |

## Troubleshooting

If something goes wrong:

1. Run `./bootstrap.sh doctor` to check your system.
2. Run `./bootstrap.sh logs` to see error messages.
3. Run `./bootstrap.sh restart` to try starting again.
4. If nothing works, start over with `./bootstrap.sh destroy` and then `./bootstrap.sh`.