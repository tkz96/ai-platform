# Architecture Decision Records

This document records the architectural decisions for the AI Platform.

## Summary

| ADR | Title | Decision |
|---|---|---|
| [ADR-001](#adr-001-isolated-inference-hardware) | Isolated Inference Hardware | Run inference on dedicated hardware |
| [ADR-002](#adr-002-litellm-as-single-api-gateway) | LiteLLM Gateway | Route all traffic through LiteLLM |
| [ADR-003](#adr-003-podman-compose-orchestration) | Podman Compose | Use Podman Compose for container orchestration |
| [ADR-004](#adr-004-immutable-containers) | Immutable Containers | Treat containers as disposable, stateless runtime units |
| [ADR-005](#adr-005-external-persistent-storage) | External Storage | Store persistent volume data outside containers |
| [ADR-006](#adr-006-private-inference-servers) | Private Inference | Restrict direct access to inference servers |

---

## ADR-001: Isolated Inference Hardware

### Context
Inference requires dedicated GPU resources. Co-locating database or web services creates resource contention.

### Decision
Separate control plane services from inference hardware.

### Consequences
- Control plane services run on dedicated hardware (Mac Mini).
- Model execution runs on dedicated GPU hardware.

---

## ADR-002: LiteLLM as Single API Gateway

### Context
Clients need a unified interface for multiple backend models without tracking individual server addresses.

### Decision
Use LiteLLM as the single OpenAI-compatible API gateway.

### Consequences
- Clients interact only with the gateway endpoint.
- Enables central authentication, rate limiting, and observability.

---

## ADR-003: Podman Compose Orchestration

### Context
The platform requires light, daemonless container management without Kubernetes complexity.

### Decision
Use Podman Compose for service orchestration.

### Consequences
- Simple YAML container declarations.
- Support for rootless container execution.

---

## ADR-004: Immutable Containers

### Context
Manual configuration changes on running containers cause configuration drift.

### Decision
Define all container configurations in source files. Never modify running containers.

### Consequences
- Redeploying containers replaces them entirely.
- Configuration changes require version control updates.

---

## ADR-005: External Persistent Storage

### Context
Container destruction must not cause data loss for databases and service state.

### Decision
Mount persistent host directories under `./data/` into containers.

### Consequences
- Containers remain disposable.
- Database storage persists across container restarts and updates.

---

## ADR-006: Private Inference Servers

### Context
Direct client access to inference servers bypasses authentication and tracing.

### Decision
Restrict network access so only LiteLLM can reach inference servers.

### Consequences
- Clients cannot bypass routing, logging, or authentication.
- Simplifies network firewall rules.