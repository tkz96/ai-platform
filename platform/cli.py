import json
import sys
from pathlib import Path
from platform.config import resolve_platform
from platform.renderer import render_all
from platform.runner import ComposeRunner
from platform.verify import format_health_table, verify_platform

import typer
from rich.console import Console

app = typer.Typer(
    name="ai-platform",
    help="Declarative self-hosted AI Platform CLI",
    add_completion=False,
)
console = Console()

ROOT_DIR = Path(__file__).parent.parent


@app.command()
def render(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
    dry_run: bool = typer.Option(False, "--dry-run", help="Validate without writing files"),
) -> None:
    """Validate platform configuration and render templates & compose.yaml."""
    target_root = root or ROOT_DIR
    console.print(f"[bold blue]Resolving platform configuration from {target_root}...[/bold blue]")

    try:
        resolved = resolve_platform(target_root)
        console.print("[bold green]✓ Configuration validated successfully.[/bold green]")

        if dry_run:
            console.print("[bold yellow]Dry run: skipping file generation.[/bold yellow]")
            return

        rendered_files = render_all(target_root, resolved)
        console.print("[bold green]✓ Generated files:[/bold green]")
        for f in rendered_files:
            rel = f.relative_to(target_root) if f.is_relative_to(target_root) else f
            console.print(f"  - [cyan]{rel}[/cyan]")
    except Exception as e:
        console.print(f"[bold red]Validation/Rendering Error:[/bold red] {e}")
        sys.exit(1)


@app.command()
def install(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Render configuration and launch all platform services."""
    target_root = root or ROOT_DIR
    render(root=target_root)

    runner = ComposeRunner()
    console.print("[bold blue]Starting platform services...[/bold blue]")
    try:
        runner.up(target_root)
        console.print("[bold green]✓ Platform services deployed successfully.[/bold green]")
    except Exception as e:
        console.print(f"[bold red]Deployment failed:[/bold red] {e}")
        sys.exit(1)


@app.command()
def status(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
    json_output: bool = typer.Option(False, "--json", help="Output as JSON"),
) -> None:
    """Validate configuration schema and check health status of services."""
    target_root = root or ROOT_DIR
    if not json_output:
        console.print("[bold blue]Validating configuration...[/bold blue]")
    resolved = resolve_platform(target_root)
    if not json_output:
        console.print("[bold green]✓ Configuration valid.[/bold green]")

    results = verify_platform(resolved)

    if json_output:
        print(json.dumps(results, indent=2))
    else:
        table = format_health_table(results)
        console.print(table)


@app.command()
def verify(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Validate configuration schema and check health status of services."""
    status(root=root)


@app.command()
def update(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Pull latest container images and redeploy services."""
    target_root = root or ROOT_DIR
    render(root=target_root)

    runner = ComposeRunner()
    console.print("[bold blue]Pulling container images...[/bold blue]")
    runner.pull(target_root)

    console.print("[bold blue]Redeploying services...[/bold blue]")
    runner.up(target_root)
    console.print("[bold green]✓ Update complete.[/bold green]")


@app.command()
def backup(
    dest: Path | None = typer.Option(None, "--dest", "-d", help="Backup destination directory"),
) -> None:
    """Backup platform database and configuration state."""
    import tarfile
    from datetime import datetime

    target_dest = dest or (ROOT_DIR / "backups")
    target_dest.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    archive_name = f"backup_{timestamp}.tar.gz"
    archive_path = target_dest / archive_name

    console.print(f"[bold blue]Backing up platform state to {archive_path}...[/bold blue]")

    with tarfile.open(archive_path, "w:gz") as tar:
        for file_name in ["platform.yaml", "versions.yaml", "compose.yaml"]:
            p = ROOT_DIR / file_name
            if p.exists():
                tar.add(p, arcname=file_name)
        configs_dir = ROOT_DIR / "configs"
        if configs_dir.exists():
            tar.add(configs_dir, arcname="configs")

    # Attempt PostgreSQL database dump if container is running
    runner = ComposeRunner()
    try:
        dump_path = target_dest / f"postgres_{timestamp}.sql"
        with open(dump_path, "w") as f:
            runner.exec(ROOT_DIR, "postgres", ["pg_dumpall", "-U", "postgres"], stdout=f)
        console.print(f"[bold green]✓ Database dump saved to {dump_path}[/bold green]")
    except Exception:
        console.print(
            "[yellow]Notice: Postgres container not running; backup includes configs only.[/yellow]"
        )

    console.print(f"[bold green]✓ Backup process completed: {archive_path}[/bold green]")


@app.command()
def restore(
    src: Path = typer.Option(..., "--src", "-s", help="Backup source archive or directory"),
) -> None:
    """Restore platform database and configuration state."""
    import tarfile

    if not src.exists():
        console.print(f"[bold red]Backup source not found at {src}[/bold red]")
        sys.exit(1)

    console.print(f"[bold blue]Restoring platform state from {src}...[/bold blue]")

    if src.is_file() and str(src).endswith((".tar.gz", ".tgz", ".tar")):
        with tarfile.open(src, "r:*") as tar:
            tar.extractall(path=ROOT_DIR)
        console.print("[bold green]✓ Configuration archives restored successfully.[/bold green]")
    elif src.is_dir():
        runner = ComposeRunner()
        for item in src.glob("*"):
            if item.name.endswith(".sql"):
                with open(item) as f:
                    runner.exec(ROOT_DIR, "postgres", ["psql", "-U", "postgres"], stdin=f)
                console.print(f"[bold green]✓ Restored SQL dump {item.name}[/bold green]")
    else:
        console.print(f"[bold red]Unsupported backup source format: {src}[/bold red]")
        sys.exit(1)

    console.print("[bold green]✓ Restore process completed.[/bold green]")


@app.command()
def destroy(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Stop and remove all containers, networks, and volumes."""
    target_root = root or ROOT_DIR
    runner = ComposeRunner()

    console.print("[bold red]Destroying platform services and volumes...[/bold red]")
    try:
        runner.down(target_root, volumes=True)
        console.print("[bold green]✓ Platform destroyed successfully.[/bold green]")
    except Exception as e:
        console.print(f"[bold red]Destroy failed:[/bold red] {e}")
        sys.exit(1)

# ── Nodes Subcommand Group ──────────────────────────────────────────────────

nodes_app = typer.Typer(
    name="nodes",
    help="Manage Linux inference cluster nodes and enrollment",
    add_completion=False,
)
app.add_typer(nodes_app, name="nodes")


@nodes_app.command("list")
def list_nodes_cmd(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
    json_output: bool = typer.Option(False, "--json", help="Output as JSON"),
) -> None:
    """List all enrolled inference nodes and their runtime state."""
    from platform.nodes import load_registry
    from rich.table import Table

    target_root = root or ROOT_DIR
    registry = load_registry(target_root)

    if json_output:
        print(json.dumps(registry.model_dump(mode="json"), indent=2))
        return

    table = Table(title=f"AI Platform Node Registry ({len(registry.nodes)} nodes)")
    table.add_column("Node ID", style="cyan", no_wrap=True)
    table.add_column("Hostname", style="white")
    table.add_column("MAC Address", style="dim")
    table.add_column("Reserved IP", style="blue")
    table.add_column("Status", style="bold")
    table.add_column("Hardware", style="magenta")
    table.add_column("Active Model", style="yellow")

    for node_id, node in sorted(registry.nodes.items()):
        status_color = "green" if node.runtime.status == "ready" else "yellow" if node.runtime.status in ("enrolled", "provisioning") else "red"
        hw = "CPU Mode"
        if node.runtime.hardware and node.runtime.hardware.gpus:
            hw = ", ".join(f"{g.name} ({g.vram_gb}GB)" for g in node.runtime.hardware.gpus)
        elif node.runtime.hardware:
            hw = f"{node.runtime.hardware.cpu} ({node.runtime.hardware.ram_gb}GB RAM)"

        active_model = node.runtime.active_model or (node.desired.models[0].model_name if node.desired.models else "N/A")
        table.add_row(
            node.identity.id,
            node.identity.hostname,
            node.identity.mac_address,
            node.identity.reserved_ip,
            f"[{status_color}]{node.runtime.status.upper()}[/{status_color}]",
            hw,
            active_model,
        )

    console.print(table)


@nodes_app.command("enroll")
def enroll_nodes_cmd(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
    host: str = typer.Option("10.42.0.1", "--host", "-h", help="Bind IP address"),
    port: int = typer.Option(8765, "--port", "-p", help="Listen port"),
) -> None:
    """Start the node enrollment listener on Mac Mini."""
    import time
    from platform.enrollment import get_session_token, run_enrollment_listener_background
    from platform.nodes import load_registry

    target_root = root or ROOT_DIR
    token = get_session_token(target_root)

    console.print(f"[bold blue]Starting node enrollment server on {host}:{port}...[/bold blue]")
    if token:
        console.print(f"[bold green]Session Token:[/bold green] [yellow]{token}[/yellow]")

    server, thread = run_enrollment_listener_background(target_root, host=host, port=port)
    console.print("[bold green]Enrollment server running.[/bold green]")
    console.print("[dim]Run this on each fresh Linux PC:[/dim]")
    console.print(f"  [cyan]wget -q http://{host}:{port}/node-enroll.sh -O node-enroll.sh && chmod +x node-enroll.sh && sudo ./node-enroll.sh --token {token}[/cyan]")
    console.print()

    try:
        while True:
            registry = load_registry(target_root)
            console.print(f"\r[dim]Waiting for nodes... ({len(registry.nodes)} enrolled). Press Ctrl+C to finish.[/dim]", end="")
            time.sleep(2)
    except KeyboardInterrupt:
        console.print("\n[bold yellow]Stopping enrollment server...[/bold yellow]")
    finally:
        server.shutdown()
        server.server_close()
        console.print("[bold green]Enrollment server stopped.[/bold green]")


@nodes_app.command("provision")
def provision_nodes_cmd(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
    node_id: str | None = typer.Option(None, "--node-id", "-n", help="Specific node ID to provision"),
) -> None:
    """Remotely provision enrolled Linux inference nodes over SSH."""
    from platform.nodes import load_registry
    from platform.provisioner import provision_all_nodes, provision_single_node

    target_root = root or ROOT_DIR
    registry = load_registry(target_root)

    if not registry.nodes:
        console.print("[bold yellow]No nodes enrolled in state/nodes.yaml.[/bold yellow]")
        return

    if node_id:
        if node_id not in registry.nodes:
            console.print(f"[bold red]Node '{node_id}' not found in registry.[/bold red]")
            sys.exit(1)
        console.print(f"[bold blue]Provisioning node {node_id}...[/bold blue]")
        res = provision_single_node(target_root, registry.nodes[node_id])
        console.print(f"Result: {res}")
    else:
        console.print(f"[bold blue]Provisioning {len(registry.nodes)} enrolled node(s)...[/bold blue]")
        results = provision_all_nodes(target_root)
        for nid, r in results.items():
            status_style = "green" if r.get("success") else "red"
            console.print(f"  - Node [cyan]{nid}[/cyan]: [{status_style}]{'SUCCESS' if r.get('success') else 'FAILED'}[/{status_style}]")


@nodes_app.command("verify")
def verify_nodes_cmd(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Verify health and connectivity of all enrolled inference nodes."""
    status(root=root)


if __name__ == "__main__":
    app()
