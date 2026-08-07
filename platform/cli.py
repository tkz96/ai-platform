import subprocess
import sys
from pathlib import Path
from platform.config import resolve_platform
from platform.renderer import render_all
from platform.verify import verify_platform

import typer
from rich.console import Console

app = typer.Typer(
    name="ai-platform",
    help="Declarative self-hosted AI Platform CLI",
    add_completion=False,
)
console = Console()

ROOT_DIR = Path(__file__).parent.parent


def get_compose_cmd() -> list[str]:
    """Detect whether podman-compose, podman compose, or docker compose is available."""
    try:
        res = subprocess.run(["podman", "compose", "version"], capture_output=True)
        if res.returncode == 0:
            return ["podman", "compose"]
    except FileNotFoundError:
        pass

    try:
        res = subprocess.run(["podman-compose", "version"], capture_output=True)
        if res.returncode == 0:
            return ["podman-compose"]
    except FileNotFoundError:
        pass

    try:
        res = subprocess.run(["docker", "compose", "version"], capture_output=True)
        if res.returncode == 0:
            return ["docker", "compose"]
    except FileNotFoundError:
        pass

    return ["podman", "compose"]


@app.command()
def render(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Validate platform configuration and render templates & compose.yaml."""
    target_root = root or ROOT_DIR
    console.print(f"[bold blue]Resolving platform configuration from {target_root}...[/bold blue]")

    try:
        resolved = resolve_platform(target_root)
        console.print("[bold green]✓ Configuration validated successfully.[/bold green]")

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

    compose_cmd = get_compose_cmd()
    cmd = compose_cmd + ["up", "-d"]
    cmd_str = " ".join(cmd)
    console.print(f"[bold blue]Starting platform services with command: {cmd_str}...[/bold blue]")
    try:
        subprocess.run(cmd, cwd=target_root, check=True)
        console.print("[bold green]✓ Platform services deployed successfully.[/bold green]")
    except subprocess.CalledProcessError as e:
        console.print(f"[bold red]Deployment failed:[/bold red] {e}")
        sys.exit(1)


@app.command()
def status(
    root: Path | None = typer.Option(None, "--root", "-r", help="Repository root directory"),
) -> None:
    """Validate configuration schema and check health status of services."""
    target_root = root or ROOT_DIR
    console.print("[bold blue]Validating configuration...[/bold blue]")
    resolved = resolve_platform(target_root)
    console.print("[bold green]✓ Configuration valid.[/bold green]")
    verify_platform(resolved, print_table=True)


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

    compose_cmd = get_compose_cmd()
    pull_cmd = compose_cmd + ["pull"]
    up_cmd = compose_cmd + ["up", "-d"]

    console.print("[bold blue]Pulling container images...[/bold blue]")
    subprocess.run(pull_cmd, cwd=target_root, check=True)

    console.print("[bold blue]Redeploying services...[/bold blue]")
    subprocess.run(up_cmd, cwd=target_root, check=True)
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
    compose_cmd = get_compose_cmd()
    try:
        dump_path = target_dest / f"postgres_{timestamp}.sql"
        cmd = compose_cmd + ["exec", "-T", "postgres", "pg_dumpall", "-U", "postgres"]
        with open(dump_path, "w") as f:
            subprocess.run(cmd, cwd=ROOT_DIR, stdout=f, stderr=subprocess.DEVNULL, check=True)
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
        for item in src.glob("*"):
            if item.name.endswith(".sql"):
                compose_cmd = get_compose_cmd()
                cmd = compose_cmd + ["exec", "-T", "postgres", "psql", "-U", "postgres"]
                with open(item) as f:
                    subprocess.run(cmd, cwd=ROOT_DIR, stdin=f, check=True)
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
    compose_cmd = get_compose_cmd()
    cmd = compose_cmd + ["down", "-v"]

    console.print("[bold red]Destroying platform services and volumes...[/bold red]")
    try:
        subprocess.run(cmd, cwd=target_root, check=True)
        console.print("[bold green]✓ Platform destroyed successfully.[/bold green]")
    except subprocess.CalledProcessError as e:
        console.print(f"[bold red]Destroy failed:[/bold red] {e}")
        sys.exit(1)


if __name__ == "__main__":
    app()
