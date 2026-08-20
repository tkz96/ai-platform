# AI Platform — Agent Guidelines

This repository contains the infrastructure for a privacy-first, self-hosted AI platform.

The primary architecture is:

* **Mac Mini / Apple Silicon** — control plane and service host
* **Linux Ubuntu PC(s)** — dedicated inference nodes
* **Private Ethernet subnet** — `10.42.0.0/24`
* **Mac control-plane IP** — `10.42.0.1`
* **Default inference-node IP** — `10.42.0.2`
* **Podman** — control-plane container runtime
* **LiteLLM** — model routing / API gateway
* **Langfuse** — observability
* **Caddy** — reverse proxy
* **FastAPI + HTMX + Alpine.js + SSE** — local control-plane dashboard

Agents working in this repository must preserve this architecture unless a change explicitly requires architectural modification.

---

## 1. Core Architectural Rules

### 1.1 Generated vs source files

The following are generated/runtime artifacts:

* `compose.yaml`
* `configs/`
* `.env`
* `secrets/`
* `.install-state`
* runtime state under `state/`
* service data directories
* backups

**Never edit generated artifacts directly.**

Declarative source belongs in:

* `platform.yaml`
* `versions.yaml`
* `services/*.yaml`
* `templates/*.j2`

Installer logic belongs in:

* `bootstrap.sh`
* `scripts/install/*.sh`
* `scripts/install/lib/*.sh`

Platform logic belongs in:

* `ai_platform/`
* `bootstrap.py`

Web UI belongs in:

* `ai_platform/web/`
* `templates/web/`

Any infrastructure change must originate from the appropriate source/configuration layer.

---

## 2. Two Installation/Provisioning Paths

The project has two distinct operator experiences.

### CLI path

```text
./bootstrap.sh
    ↓
interactive installation orchestration
    ↓
scripts/install/*
    ↓
reusable infrastructure operations
```

### Web path

```text
Dashboard
    ↓
FastAPI API
    ↓
SetupEngine / provisioning orchestrator
    ↓
non-interactive reusable infrastructure operations
```

These paths may share implementation primitives, but they must not depend on the same interactive presentation layer.

### Important rule

**Do not execute an interactive installer script from the web dashboard merely because it is convenient.**

Web provisioning must never block waiting for:

* `stdin`
* `read`
* `ui_confirm`
* `ui_choice`
* `ui_prompt_text`
* terminal-only operator input

Any operation requiring user choice must expose that choice explicitly through the web/API layer or have a safe, deterministic non-interactive mode.

---

## 3. `NONINTERACTIVE` Contract

`NONINTERACTIVE=1` is an explicit execution contract.

When present:

```bash
NONINTERACTIVE=1
```

installer code must:

* never wait for stdin
* never call interactive prompts without a documented programmatic fallback
* never hang indefinitely
* fail with a structured, actionable error when required information is missing
* use deterministic defaults only when those defaults are safe
* report what information is missing when no safe default exists

Every installer phase must follow the same semantics.

Before changing a phase, search for:

```text
NONINTERACTIVE
read
ui_confirm
ui_choice
ui_prompt_text
ui_recoverable
```

---

## 4. Provisioning Phases

The canonical web provisioning phases currently include:

1. `05-podman`
2. `06a-networking`
3. `07-secrets`
4. `08-render`
5. `09-deploy`
6. `10-verify`

Execution order matters.

A phase must not assume that a later phase has already run.

A phase should be:

* idempotent
* retryable
* safe to rerun
* explicit about prerequisites
* explicit about failure
* independently testable

Do not reorder phases without understanding their dependencies.

---

## 5. Podman Machine Management

Podman runs the control-plane container stack on macOS.

The machine name is normally:

```text
ai-platform
```

### Machine existence

Do not treat an `already exists` response from:

```bash
podman machine init
```

as proof that the machine is healthy.

A valid machine must be verified using Podman machine inspection/state.

The following states must be distinguished:

1. Machine absent
2. Machine exists and stopped
3. Machine exists and running
4. Machine metadata exists but underlying VM is broken/stale
5. Machine exists but `podman info` cannot communicate with it

### Recovery

Podman lifecycle code must:

* preserve configured CPU count
* preserve configured memory
* preserve configured disk size
* avoid hard-coded machine settings in low-level helpers
* safely remove stale/broken machines
* recreate them when appropriate
* verify readiness with `podman info`
* remain idempotent

Never destroy a healthy Podman machine merely because a command returned an unexpected message.

When recovery is required, emit a clear diagnostic explaining:

* what was detected
* why it is considered stale/broken
* what is being removed
* what will be recreated

---

## 6. Networking Architecture

The private inference network is:

```text
10.42.0.0/24
```

Expected topology:

```text
Internet / WAN
      |
      v
Mac Mini
  WAN interface
      |
  Control Plane
  10.42.0.1
      |
Private Ethernet
      |
  Linux Node
  10.42.0.2
```

The private Ethernet interface must never be assumed to be the WAN interface.

### WAN safety

Never silently repurpose the interface carrying the Mac's primary Internet/default route.

Before changing an interface:

* identify the current WAN/default-route interface
* identify physical Ethernet candidates
* determine link state
* verify the selected interface is appropriate
* require explicit confirmation in interactive mode when a dangerous ambiguity exists
* expose a structured choice in web mode

Never make a destructive networking decision merely because only one interface was detected.

---

## 7. Networking Responsibilities

Networking currently involves several logically distinct responsibilities:

* physical Ethernet discovery
* private interface selection
* static IP assignment
* DHCP
* PF/NAT
* packet forwarding
* cluster SSH keys
* enrollment tokens
* enrollment server lifecycle
* Linux-node enrollment
* remote provisioning
* cluster verification

Avoid adding further unrelated responsibility to one monolithic shell script.

When modifying networking, prefer reusable primitives in:

```text
scripts/install/lib/networking.sh
```

and/or appropriate Python modules where programmatic orchestration is required.

Keep interactive prompts out of reusable infrastructure functions.

---

## 8. Enrollment

The Linux inference node enrollment workflow must be reliable and resumable.

The system may generate:

* cluster SSH keypair
* enrollment token
* temporary enrollment server
* node registration data
* node provisioning state

Enrollment server startup and cleanup must be deterministic.

Any temporary server/process started during setup must have reliable cleanup through success, failure, interruption, and cancellation.

### Import/package correctness

The repository package namespace is:

```python
ai_platform
```

Do not introduce or preserve stale imports such as:

```python
from platform....
```

unless the repository explicitly contains and requires such a compatibility namespace.

Before changing an import, verify the actual module tree.

---

## 9. CLI and Web Must Share Core Operations

Avoid duplicating infrastructure logic between:

```text
bootstrap.sh
scripts/install/*
ai_platform/setup/*
ai_platform/provisioner.py
ai_platform/lifecycle.py
ai_platform/service_manager.py
ai_platform/enrollment.py
```

Prefer:

```text
Interactive CLI
      |
      v
Provisioning Orchestrator
      |
      v
Reusable Infrastructure Operations
```

rather than:

```text
CLI implementation
+
Web implementation
+
duplicate shell implementation
+
duplicate Python implementation
```

Use DRY principles, but do not create unnecessary abstraction layers.

Use YAGNI.

A small shared function is preferable to a large generic framework.

---

## 10. Web Provisioning and SSE

The dashboard provisions through:

```text
GET /api/setup/stream?phase=<phase>
```

The browser uses Server-Sent Events.

Expected event types include:

* `step_start`
* `log`
* `step_done`
* `error`
* `complete`

The SSE system must correctly handle:

* long-running phases
* subprocess output
* subprocess failures
* client disconnects
* cleanup
* cancellation
* retries
* concurrent execution attempts
* state refresh
* partial completion

Never allow a subprocess to remain orphaned after its controlling execution is cancelled or disconnected.

Do not assume that a browser disconnect means the provisioning process should automatically continue. Define that behavior explicitly.

---

## 11. Provisioning Locking

The repository uses a setup execution lock.

Before modifying provisioning concurrency:

* inspect how `_SETUP_LOCK` is acquired
* inspect how generators are nested
* inspect concurrent browser requests
* inspect what happens when an execution fails
* inspect what happens when the browser disconnects

A nested generator must not accidentally acquire the same non-reentrant lock twice.

Avoid designs where:

```text
stream_all_phases_execution()
    ↓
stream_phase_execution()
    ↓
acquire same lock again
```

causes a self-deadlock.

Use one clearly defined concurrency boundary.

Only one provisioning sequence should modify system state at a time unless a stronger concurrency model is deliberately introduced.

---

## 12. Provisioning State

The dashboard uses empirical readiness checks and the repository also has installation state.

Do not create competing definitions of success.

A phase should only be considered complete when its actual required condition is satisfied.

Examples:

### Podman

Not merely:

```text
podman machine init succeeded
```

but:

```text
machine exists
+
machine running
+
podman info succeeds
```

### Networking

Not merely:

```text
network script exited 0
```

but the required:

* interface configuration
* DHCP state
* NAT state
* connectivity

must actually be present.

### Deployment

Not merely:

```text
compose up exited 0
```

but required services must be running/healthy.

### Verification

Verification must reflect the actual final system state.

Do not mark a phase complete solely because a previous command succeeded.

---

## 13. `.install-state`

`.install-state` is generated state.

Do not manually edit it as part of normal development.

When modifying state behavior:

* preserve resumability
* preserve retries
* preserve failure visibility
* do not permanently mark failed phases as successful
* do not create stale `in_progress` states
* ensure rerunning a phase is safe

Empirical system state should remain authoritative for whether infrastructure is actually functioning.

Persisted state may be used for orchestration/history, but must not override observable reality.

---

## 14. Dashboard Port Management

The dashboard currently uses:

```text
127.0.0.1:8888
```

Port handling must be deterministic.

Before starting the dashboard:

1. Determine whether the configured port is free.
2. Identify the owning process when occupied.
3. Determine whether it is already a healthy AI Platform dashboard.
4. If it is an existing healthy dashboard, reuse it instead of spawning another server.
5. If it is an unrelated process, follow the repository's explicit conflict policy.
6. If an alternative port is selected, propagate that port to:

   * Uvicorn
   * printed URL
   * browser launch
   * any runtime configuration that depends on it

Never:

```text
detect occupied port
→ print warning
→ launch on the same occupied port anyway
```

Never hard-code the dashboard URL in one location while dynamically selecting a different port elsewhere.

---

## 15. Generated Configuration

Use:

```bash
uv run python bootstrap.py render
```

for configuration validation/rendering.

Do not manually edit:

* `compose.yaml`
* generated Caddyfiles
* generated LiteLLM configuration
* generated environment files

Source changes belong in:

* `platform.yaml`
* `versions.yaml`
* `services/*.yaml`
* `templates/*.j2`
* rendering code

---

## 16. Service Definitions

Service manifests live in:

```text
services/*.yaml
```

Use them as the source of truth for service configuration and port declarations.

Avoid:

* hard-coded service lists
* duplicated port definitions
* special-case logic for one service when a manifest-driven mechanism is appropriate

When service topology changes, update the declarative source first.

---

## 17. Error Handling

Errors must be:

* explicit
* actionable
* bounded
* recoverable where appropriate

Avoid:

```bash
while true
```

loops without a meaningful termination path.

Avoid infinite retry loops that hide the root cause.

Use retries only when:

* the failure is expected to be transient
* there is a clear readiness condition
* there is a bounded retry policy

Do not use arbitrary `sleep` calls where a proper readiness/health check can be implemented.

---

## 18. Security Rules

Never:

* print secrets unnecessarily
* commit secrets
* expose private keys
* weaken SSH host verification without justification
* disable firewall/network protections casually
* repurpose the WAN interface silently
* expose enrollment endpoints beyond their intended network

Sensitive files must remain untracked/generated:

```text
.env
secrets/
state/
.install-state
```

When working with enrollment tokens or API keys, prefer file-backed or environment-backed handling rather than embedding credentials in source.

---

## 19. Shell Script Standards

Shell scripts must use:

```bash
set -euo pipefail
```

Scripts should:

* quote variables
* use explicit local variables
* check command results
* clean up temporary processes/files
* use traps where necessary
* avoid global state where practical
* avoid parsing human-readable command output when structured output is available

Shell helper functions should have one clear responsibility.

---

## 20. Python Standards

Python code should:

* use type hints
* follow existing project structure
* use `pathlib.Path` for filesystem operations
* avoid hidden global state
* provide useful exception messages
* avoid broad exception swallowing
* keep infrastructure side effects explicit

Do not introduce a new framework or dependency for a problem that can be solved with existing project tools.

---

## 21. Testing Requirements

Before declaring a provisioning change complete, test the affected layer and then the complete flow.

At minimum, consider:

### Unit tests

* Podman state detection
* stale machine recovery
* port selection
* readiness logic
* phase-state transitions
* orchestration logic

### Shell/integration tests

* Podman machine lifecycle
* networking primitives
* secrets generation
* rendering
* deployment
* verification

### Web/SSE tests

* individual phase execution
* all-phase execution
* SSE event ordering
* failures
* client disconnect
* concurrent execution protection
* retry behavior

### End-to-end tests

Test at minimum:

1. Fresh Mac installation
2. Existing healthy Podman machine
3. Stale Podman machine
4. Missing Podman VM
5. Dashboard port available
6. Dashboard port occupied by unrelated process
7. Dashboard already running
8. Web provisioning from Podman through verification
9. Network provisioning
10. Linux-node enrollment
11. Phase failure and retry
12. Browser refresh during provisioning
13. Browser disconnect during provisioning
14. Re-running completed provisioning
15. CLI installation
16. CLI retry after failure
17. Inference node unreachable
18. Inference node reachable
19. Restart/recovery
20. Clean teardown

---

## 22. Validation Commands

Run the appropriate checks after every meaningful infrastructure change.

Standard validation:

```bash
make lint
make test
```

Python formatting:

```bash
uv run ruff format --check .
```

Python linting:

```bash
uv run ruff check .
```

YAML validation:

```bash
uv run yamllint .
```

Configuration validation:

```bash
uv run python bootstrap.py render --dry-run
```

Where relevant, also exercise:

```bash
./bootstrap.sh doctor
./bootstrap.sh status
./bootstrap.sh verify
```

Do not claim a change is complete without testing the changed execution path.

---

## 23. Repository-Wide Debugging Rules

When investigating a bug:

1. Reproduce the actual failure.
2. Trace the complete execution path.
3. Identify the first incorrect assumption/state transition.
4. Fix the underlying cause rather than hiding the symptom.
5. Check adjacent paths for the same bug pattern.
6. Add or update tests.
7. Re-run the original reproduction.
8. Re-run the affected end-to-end flow.

For provisioning issues, trace:

```text
UI
→ HTTP/SSE
→ SetupEngine
→ phase orchestration
→ shell/Python operation
→ host/Podman/network state
→ empirical readiness
→ UI refresh
```

Do not assume the visible UI symptom is the root cause.

---

## 24. Change Scope

Follow YAGNI and minimize unrelated refactoring.

Do not:

* redesign the whole platform for a local bug
* rename large numbers of files without necessity
* replace Podman with Docker
* replace the existing dashboard stack without cause
* introduce new dependencies without need
* refactor unrelated services while fixing provisioning

Prefer small sequential changes with clear verification points.

When architectural refactoring is genuinely required, separate it into explicit steps so each intermediate state remains testable.

---

## 25. Definition of Done for Provisioning Changes

A provisioning change is complete only when:

* the affected phase is idempotent
* failure is reported clearly
* retry works
* already-satisfied state is detected correctly
* web execution does not require stdin
* CLI execution remains functional
* SSE output reflects actual execution
* subprocesses are cleaned up
* state reflects real system health
* generated artifacts remain generated
* tests cover the failure mode
* `make lint` passes
* `make test` passes
* the original reproduction no longer fails

The goal is not merely for the script to exit successfully.

The goal is for the **Mac control plane and Linux inference architecture to reach a verified, usable state through both CLI and web provisioning paths.**
