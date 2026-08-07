# Operations

## Purpose

This document describes how to operate the platform.

---

# Daily Commands

Start

```bash
podman compose up -d
```

Stop

```bash
podman compose down
```

Restart

```bash
podman compose restart
```

View Logs

```bash
podman compose logs -f
```

View Running Containers

```bash
podman ps
```

---

# Updating Images

```bash
podman compose pull

podman compose up -d
```

---

# Backups

Back up:

- PostgreSQL
- ClickHouse
- Redis

Do NOT rely solely on container volumes.

---

# Restore

1. Install Podman
2. Clone repository
3. Restore data/
4. Start compose

---

# Disaster Recovery

Goal:

Rebuild an entire AI Platform from scratch within one hour.

---

# Monitoring

Regularly inspect:

- container health
- disk usage
- database size
- inference latency
- GPU utilization

---

# Troubleshooting

## LiteLLM unavailable

Check:

- container running
- config.yaml
- inference server reachable

---

## Langfuse unavailable

Check:

- PostgreSQL
- ClickHouse
- Redis

---

## Inference unavailable

Check:

- llama.cpp
- GPU
- firewall
- LiteLLM routing

---

# Maintenance Philosophy

Infrastructure should be reproducible.

Never manually patch running containers.

Update the configuration.

Redeploy.
