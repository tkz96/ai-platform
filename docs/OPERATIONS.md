# Operations Guide

This document describes how to operate, maintain, and troubleshoot the AI Platform.

## Daily Operations

Run commands from the repository root directory.

### Operations Commands

| Action | Command |
|---|---|
| Start platform | `make install` |
| View service status | `make status` |
| Validate configuration | `make render` |
| Run health checks | `make verify` |
| Pull and update images | `make update` |
| Backup database and state | `make backup` |
| Restore from backup | `uv run python bootstrap.py restore --src <path>` |
| Destroy containers and volumes | `make destroy` |

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

## Backup and Restore

### Create a Backup

Run the backup target:

```bash
make backup
```

This command creates a timestamped archive in `backups/` containing:
- Platform configuration files (`platform.yaml`, `versions.yaml`, `compose.yaml`)
- Service configuration directory (`configs/`)
- PostgreSQL database dump (`postgres_<timestamp>.sql`)

### Restore from Backup

1. Stop existing platform services:
   ```bash
   make destroy
   ```

2. Restore configuration and state from a backup archive:
   ```bash
   uv run python bootstrap.py restore --src backups/backup_<timestamp>.tar.gz
   ```

3. Deploy platform services:
   ```bash
   make install
   ```

## Disaster Recovery

To rebuild the control plane on a new machine:

1. Install prerequisites (Python ≥ 3.12, `uv`, Podman, Podman Compose).
2. Clone the repository:
   ```bash
   git clone git@github.com:<user>/ai-platform.git
   cd ai-platform
   ```
3. Install dependencies:
   ```bash
   uv sync
   ```
4. Create the environment file (`.env`) with production credentials.
5. Restore from a backup archive if available:
   ```bash
   uv run python bootstrap.py restore --src <backup-file>
   ```
6. Render and deploy:
   ```bash
   make install
   ```

Target recovery time: < 15 minutes.

## Monitoring and Maintenance

Perform these routine checks:

- [ ] Run `make verify` to confirm HTTP endpoints respond.
- [ ] Inspect disk space for persistent volumes in `./data/`.
- [ ] Check container restart counts with `podman ps`.
- [ ] Verify GPU memory and temperature on the inference server.

## Troubleshooting

| Service / Issue | Possible Cause | Verification | Solution |
|---|---|---|---|
| LiteLLM endpoint failing | Container stopped or un-rendered config | `make status` | Check logs with `podman compose logs litellm` |
| LiteLLM cannot reach inference | Inference server offline or port blocked | `curl http://<inference_host>:<port>/health` | Verify inference server status and network connectivity |
| Langfuse UI unavailable | Relational or analytics database offline | `make status` | Ensure `postgres`, `clickhouse`, and `redis` containers are healthy |
| Render command fails | Configuration schema error | `make render` | Fix syntax errors in `platform.yaml` or `services/*.yaml` |
