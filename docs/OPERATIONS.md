# Operations Guide

This document describes how to operate, maintain, and troubleshoot the AI Platform.

## Daily Operations

Run commands from the repository root directory.

### Operations Commands

The primary interface for all operations is `bootstrap.sh`:

| Action | Command |
|---|---|
| Start platform | `./bootstrap.sh start` |
| Stop platform | `./bootstrap.sh stop` |
| Restart platform | `./bootstrap.sh restart` |
| View service status | `./bootstrap.sh status` |
| Validate configuration | `./bootstrap.sh verify` |
| Check machine readiness | `./bootstrap.sh doctor` |
| Update platform | `./bootstrap.sh update` |
| Backup database and state | `./bootstrap.sh backup` |
| Restore from backup | `./bootstrap.sh restore --src <path>` |
| View logs | `./bootstrap.sh logs` |
| View logs for one service | `./bootstrap.sh logs litellm` |
| Destroy containers and volumes | `./bootstrap.sh destroy` |

### Direct Container Management

Use Podman Compose directly for live log inspection or container status:

```bash
# View live logs for all services
podman compose logs -f

# View live logs for a single service
podman compose logs -f litellm

# List active containers
podman ps
```

## Update Procedure

The `./bootstrap.sh update` command provides a safe, reviewable update process:

1. **Fetch** — Downloads the latest code from GitHub.
2. **Review** — Shows you what changed (commits and version differences).
3. **Confirm** — Asks you to proceed before making any changes.
4. **Backup** — Creates a pre-update backup automatically.
5. **Pull** — Updates the code.
6. **Render** — Regenerates configuration.
7. **Deploy** — Restarts services with new configuration.
8. **Verify** — Runs health checks on all services.

If any step fails, the platform restores from the pre-update backup.

### Example Update Session

```
AI Platform Update

Changes since current version:
  - feat: add retry logic to LiteLLM
  - fix: handle Langfuse v3 API changes

Version Changes:
  - litellm: 1.95.0 → 1.96.0

Proceed with update? [y/N]:
```

## Backup and Restore

### Create a Backup

```bash
./bootstrap.sh backup
```

This command creates a timestamped archive in `backups/` containing:
- Platform configuration files (`platform.yaml`, `versions.yaml`, `compose.yaml`)
- Service configuration directory (`configs/`)
- PostgreSQL database dump (`postgres_<timestamp>.sql`)

### Restore from Backup

1. Stop existing platform services:
   ```bash
   ./bootstrap.sh stop
   ```

2. Restore configuration and state from a backup archive:
   ```bash
   ./bootstrap.sh restore --src backups/backup_<timestamp>.tar.gz
   ```

3. Deploy platform services:
   ```bash
   ./bootstrap.sh start
   ```

## Disaster Recovery

To rebuild the control plane on a new machine:

1. Ensure the Mac meets the requirements (macOS 14+, Apple Silicon, 60 GB disk, 8 GB RAM).
2. Clone the repository:
   ```bash
   git clone git@github.com:tkz96/ai-platform.git
   cd ai-platform
   ```
3. Run the installer:
   ```bash
   ./bootstrap.sh
   ```
4. If you have a backup, restore it:
   ```bash
   ./bootstrap.sh restore --src <backup-file>
   ```

Target recovery time: < 15 minutes.

## Monitoring and Maintenance

Perform these routine checks:

- [ ] Run `./bootstrap.sh doctor` to verify machine readiness.
- [ ] Run `./bootstrap.sh status` to confirm HTTP endpoints respond.
- [ ] Inspect disk space for persistent volumes in `./data/`.
- [ ] Check container restart counts with `podman ps`.
- [ ] Verify GPU memory and temperature on the inference server.

## Troubleshooting

| Service / Issue | Possible Cause | Verification | Solution |
|---|---|---|---|
| Mac cannot ping 10.42.0.2 | Ethernet cable unplugged or wrong NIC | `./bootstrap.sh doctor` | Check physical cable, run `ifconfig`, or rerun `./bootstrap.sh connect-inference` |
| TCP 8080 closed on 10.42.0.2 | llama-server not running on Linux PC | `nc -z 10.42.0.2 8080` | On Linux PC, verify listener: `ss -lntp \| grep :8080` and start `llama-server --host 10.42.0.2 --port 8080` |
| Mac host OK but Podman VM fails | Podman VM networking issue | `./bootstrap.sh doctor` | Restart Podman machine: `podman machine stop && podman machine start` |
| LiteLLM cannot reach inference | Pinned host/port mismatch or firewall | `curl http://10.42.0.2:8080/health` | Check `INFERENCE_HOST` in `.env` and Linux firewall |
| LiteLLM endpoint failing | Container stopped or un-rendered config | `./bootstrap.sh status` | Check logs with `./bootstrap.sh logs litellm` |
| Langfuse UI unavailable | Relational or analytics database offline | `./bootstrap.sh status` | Ensure `postgres`, `clickhouse`, and `redis` containers are healthy |
| Render command fails | Configuration schema error | `make render` | Fix syntax errors in `platform.yaml` or `services/*.yaml` |
| Podman machine not running | Machine stopped or not initialized | `./bootstrap.sh doctor` | Run `./bootstrap.sh` to initialize and start the machine |
| Port conflict | Another process using a required port | `./bootstrap.sh doctor` | Stop the conflicting process or use an alternative port |