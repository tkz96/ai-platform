# AI Platform Context

## Overview

This repository contains the infrastructure for XynoTech's internal AI Platform.

The objective is to create a clean, maintainable, self-hosted AI stack that can serve multiple developers, autonomous agents, IDEs, and future services through a single gateway.

This repository is considered the **single source of truth** for the infrastructure.

Infrastructure changes should always be declarative and reproducible.

---

# Design Philosophy

This project follows these principles:

1. Single Responsibility
2. Infrastructure as Code
3. Declarative Configuration
4. Immutable Infrastructure
5. Security by Default
6. Simplicity over Cleverness
7. DRY
8. YAGNI
9. Least Privilege
10. Reproducibility

Any architectural decision should reinforce these principles.

---

# Overall Architecture

                   Developers
                        │
                        │
        ┌────────────────────────────────┐
        │                                │
        ▼                                ▼
 MacBook Air                     Friend's Laptop
        │                                │
        └──────────────┬─────────────────┘
                       │
                OpenAI-compatible API
                       │
                       ▼
              Mac Mini (Control Plane)
        ┌──────────────────────────────────┐
        │                                  │
        │ LiteLLM                          │
        │ Langfuse                         │
        │ PostgreSQL                       │
        │ ClickHouse                       │
        │ Redis                            │
        │ Reverse Proxy (future)           │
        │ Authentication (future)          │
        └──────────────────────────────────┘
                       │
                 Private LAN only
                       │
                       ▼
             Inference PC (Private)
        ┌──────────────────────────────────┐
        │ llama.cpp                        │
        │ CUDA                             │
        │ Qwen Models                      │
        └──────────────────────────────────┘

---

# Machine Responsibilities

## Mac Mini

This machine is the control plane.

It manages:

- LiteLLM
- Langfuse
- PostgreSQL
- ClickHouse
- Redis
- Reverse Proxy
- Authentication
- Monitoring

This machine does NOT perform inference.

---

## Inference PC

This machine performs one job only:

Generate tokens.

It should never host:

- Databases
- Dashboards
- Langfuse
- LiteLLM
- Monitoring
- Authentication

Inference should remain isolated.

---

## Developer Machines

Developer machines contain no infrastructure.

Developers connect to LiteLLM using an OpenAI-compatible endpoint.

Developer operating systems and tooling are intentionally unrestricted.

---

# Repository Purpose

This repository contains:

- compose.yaml
- configuration
- infrastructure scripts
- documentation

This repository should NOT contain:

- application source code
- cloned third-party repositories
- databases
- logs
- caches
- virtual environments
- generated artifacts

---

# Expected Directory Structure

.
├── compose.yaml
├── README.md
├── configs
│   ├── litellm
│   ├── langfuse
│   └── caddy
├── data
│   ├── postgres
│   ├── clickhouse
│   └── redis
├── backups
└── scripts

---

# Containers

Services should run as containers.

Do not install application software directly onto the host unless it is part of the operating system.

Containers are disposable.

Persistent data is not.

---

# Persistent Data

All persistent data belongs inside:

data/

Container recreation must never destroy persistent data.

---

# Networking

The architecture follows a hub-and-spoke model.

Clients communicate ONLY with LiteLLM.

LiteLLM communicates with inference servers.

Inference servers should never be directly exposed to clients.

Future firewall rules should only allow LiteLLM to communicate with inference services.

---

# Security Principles

Default deny.

Only expose required ports.

Never expose databases publicly.

Never expose inference directly.

Prefer internal networking.

Secrets belong in environment variables.

Secrets must never be committed to Git.

---

# Configuration

Configuration belongs inside:

configs/

Configuration should never be duplicated.

Configuration should never be embedded into container images.

---

# Infrastructure Philosophy

Everything should be reproducible from scratch.

A new machine should be deployable by cloning this repository and executing a minimal deployment procedure.

Manual configuration should be avoided whenever possible.

---

# Future Services

The architecture should make it easy to add services such as:

- Caddy
- Prometheus
- Grafana
- OpenTelemetry Collector
- SearXNG
- Vector Databases
- Additional inference servers
- Authentication providers

Adding new services should require minimal structural changes.

---

# AI Agent Guidelines

Before making changes:

- Understand the current architecture.
- Preserve existing abstractions.
- Prefer simple solutions.
- Avoid introducing unnecessary dependencies.
- Do not duplicate configuration.
- Do not create additional compose files unless there is a compelling architectural reason.
- Keep infrastructure modular.
- Favor maintainability over convenience.
- Document significant architectural decisions.

If multiple solutions exist, prefer the one that:

- reduces operational complexity
- improves reproducibility
- minimizes maintenance burden
- follows existing project conventions

---

# Long-Term Vision

This repository should evolve into the central infrastructure for an internal AI platform capable of serving:

- developers
- coding agents
- IDE integrations
- CI/CD systems
- autonomous software engineering agents
- future internal applications

through a single, secure, observable, OpenAI-compatible gateway.

Every architectural decision should move the project closer to this goal.