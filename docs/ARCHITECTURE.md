# Architecture

This document describes the technical architecture of the AI Platform.

For design rationale, see [DECISIONS.md](DECISIONS.md).

## System Overview

The platform runs on two machines. The control plane hosts routing, observability, and storage as containers. The inference server runs models.

```mermaid
graph TD
    Dev["Developers / AI Agents"]
    Dev -->|"OpenAI-compatible API"| Caddy

    subgraph CP["Control Plane (Mac Mini)"]
        Caddy["Caddy (reverse proxy)"]
        Caddy --> LiteLLM
        Caddy --> Langfuse

        LiteLLM["LiteLLM (API gateway)"]
        LiteLLM --> Postgres
        LiteLLM -.->|"traces"| Langfuse

        Langfuse["Langfuse (observability)"]
        Langfuse --> Postgres
        Langfuse --> ClickHouse
        Langfuse --> Redis

        Postgres["PostgreSQL"]
        ClickHouse["ClickHouse"]
        Redis["Redis"]
    end

    LiteLLM -->|"internal network"| Inference

    subgraph INF["Inference Server"]
        Inference["llama.cpp + CUDA"]
    end
```

## Service Responsibilities

| Service | Role | Port |
|---|---|---|
| Caddy | Reverse proxy, TLS termination | 80, 443 |
| LiteLLM | OpenAI-compatible API gateway, model routing | 4000 |
| Langfuse | Trace logging, cost tracking, latency monitoring | 3000 |
| PostgreSQL | Persistent relational storage (LiteLLM, Langfuse) | 5432 |
| ClickHouse | Analytics and event storage (Langfuse) | 8123 |
| Redis | Caching and background jobs (Langfuse) | 6379 |

Clients never access databases or inference servers directly. All traffic enters through Caddy.

## Request Flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant C as Caddy
    participant L as LiteLLM
    participant LF as Langfuse
    participant I as Inference Server

    Dev->>C: API request
    C->>L: Route to LiteLLM
    L->>LF: Create trace
    L->>I: Forward to model
    I-->>L: Model response
    L->>LF: Complete trace
    L-->>C: Return response
    C-->>Dev: API response
```

## Service Dependencies

The platform starts services in topological order. A service starts only after its dependencies are healthy.

```mermaid
graph BT
    Postgres
    ClickHouse
    Redis
    Langfuse --> Postgres
    Langfuse --> ClickHouse
    Langfuse --> Redis
    LiteLLM --> Postgres
    Caddy --> LiteLLM
    Caddy --> Langfuse
```

## Configuration Pipeline

Source files produce generated files. Never edit generated files directly.

```mermaid
flowchart LR
    PY["platform.yaml"] --> Resolver
    VY["versions.yaml"] --> Resolver
    SM["services/*.yaml"] --> Resolver
    Resolver["Python resolver"] --> Renderer
    TJ["templates/*.j2"] --> Renderer
    Renderer["Jinja2 renderer"] --> CY["compose.yaml"]
    Renderer --> CF["configs/*"]

    style CY fill:#fee,stroke:#c00
    style CF fill:#fee,stroke:#c00
```

| Layer | Files | Editable |
|---|---|---|
| Configuration | `platform.yaml`, `versions.yaml` | Yes |
| Service manifests | `services/*.yaml` | Yes |
| Templates | `templates/**/*.j2` | Yes |
| Python logic | `platform/` | Yes |
| Generated output | `compose.yaml`, `configs/` | **No** |

## Network Model

All services share a single bridge network (`ai-platform`).

- Clients connect through Caddy on ports 80/443.
- Inference servers accept requests only from LiteLLM.
- Databases are not exposed outside the container network in production.

## Security Model

- Secrets are stored in `.env`, which is excluded from Git.
- Containers use official upstream images.
- Services follow least-privilege defaults.
- Configuration is validated before deployment.

## Persistent Storage

| Service | Volume | Data |
|---|---|---|
| PostgreSQL | `./data/postgres` | User data, LiteLLM state, Langfuse metadata |
| ClickHouse | `./data/clickhouse` | Traces and analytics events |
| Redis | `./data/redis` | Cache and job queue state |

Containers are disposable. Persistent state lives in volumes under `data/`.

The `data/` directory is excluded from Git.