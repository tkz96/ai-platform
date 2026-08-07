# Architecture Decisions

This document records important architectural decisions.

Future AI agents should consult this file before making major changes.

---

# ADR-001

## Decision

Inference will be isolated onto dedicated hardware.

## Reason

Inference workloads should not compete with infrastructure workloads.

---

# ADR-002

## Decision

LiteLLM is the single API gateway.

## Reason

Clients should not need to know where inference occurs.

---

# ADR-003

## Decision

Infrastructure is managed using Podman Compose.

## Reason

Declarative infrastructure is reproducible and easier to maintain.

---

# ADR-004

## Decision

Containers are immutable.

## Reason

Configuration should be version controlled.

Running containers should never become unique snowflakes.

---

# ADR-005

## Decision

Persistent data is stored outside containers.

## Reason

Containers must remain disposable.

---

# ADR-006

## Decision

Inference servers are private.

## Reason

All access should flow through LiteLLM.

This enables authentication, observability, rate limiting, and future load balancing.