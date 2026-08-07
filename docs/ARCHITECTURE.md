# Architecture

## Purpose

This document describes the technical architecture of the AI Platform.

Unlike CONTEXT.md, this document focuses on implementation rather than philosophy.

---

# High-Level Architecture

```
                    Developers
                         │
                         │
         OpenAI Compatible API Requests
                         │
                         ▼
                 Mac Mini (Control Plane)
        ┌──────────────────────────────────────┐
        │                                      │
        │ LiteLLM Gateway                      │
        │ Langfuse                             │
        │ PostgreSQL                           │
        │ ClickHouse                           │
        │ Redis                               │
        │ Reverse Proxy (Future)              │
        │ Monitoring (Future)                 │
        └──────────────────────────────────────┘
                         │
                Private Internal Network
                         │
                         ▼
                 Inference Server(s)
        ┌──────────────────────────────────────┐
        │ llama.cpp                            │
        │ CUDA                                │
        │ Local GGUF Models                   │
        └──────────────────────────────────────┘
```

---

# Responsibilities

## LiteLLM

Single OpenAI-compatible API endpoint.

Responsibilities:

- Model routing
- Authentication
- Usage accounting
- Rate limiting
- Future load balancing
- Future failover

---

## Langfuse

Observability.

Responsibilities:

- Prompt logging
- Trace visualization
- Cost tracking
- Latency monitoring
- Evaluation

---

## PostgreSQL

Persistent relational storage.

Should never be accessed directly by clients.

---

## ClickHouse

Analytics database.

Stores traces and events.

---

## Redis

Queueing.

Caching.

Background jobs.

---

# Request Flow

Developer

↓

LiteLLM

↓

Langfuse Trace Created

↓

Inference Server

↓

Response

↓

Langfuse Trace Completed

↓

Developer

---

# Network Model

Clients never communicate directly with inference servers.

Inference servers should only accept requests originating from LiteLLM.

---

# Security Model

Principles:

- Default deny
- Internal networking
- No public databases
- Secrets stored outside Git
- Least privilege

---

# Persistent Storage

Persistent volumes:

- PostgreSQL
- ClickHouse
- Redis

Containers should always remain replaceable.

---

# Future Expansion

Planned additions include:

- Reverse proxy
- TLS
- Authentication
- Multiple inference servers
- Load balancing
- Vector databases
- SearXNG
- Prometheus
- Grafana
- OpenTelemetry Collector