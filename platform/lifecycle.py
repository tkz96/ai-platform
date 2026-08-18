from __future__ import annotations

import tarfile
from datetime import datetime
from pathlib import Path
from platform.config import ResolvedPlatform, resolve_platform
from platform.renderer import render_all
from platform.runner import ComposeRunner


class PlatformLifecycle:
    """Encapsulates the complete lifecycle of the platform:

    configuration resolution, template rendering, container orchestration,
    and backup/restore operations.
    """

    def __init__(self, root_dir: Path, runner: ComposeRunner | None = None) -> None:
        self.root_dir = root_dir
        self.runner = runner or ComposeRunner()

    def render(self, env_vars: dict[str, str] | None = None) -> tuple[ResolvedPlatform, list[Path]]:
        """Validate platform configuration and render all service configs and compose.yaml."""
        resolved = resolve_platform(self.root_dir, env_vars=env_vars)
        rendered_files = render_all(self.root_dir, resolved)
        return resolved, rendered_files

    def deploy(self, detached: bool = True, env_vars: dict[str, str] | None = None) -> list[Path]:
        """Render platform and start all compose services."""
        _, rendered_files = self.render(env_vars=env_vars)
        self.runner.up(self.root_dir, detached=detached)
        return rendered_files

    def update(self) -> None:
        """Pull latest container images and redeploy."""
        self.render()
        self.runner.pull(self.root_dir)
        self.runner.up(self.root_dir, detached=True)

    def teardown(self, volumes: bool = False) -> None:
        """Stop and remove compose containers, networks, and optionally volumes."""
        self.runner.down(self.root_dir, volumes=volumes)

    def create_backup(self, dest_dir: Path | None = None) -> tuple[Path, Path | None]:
        """Create a tarball backup of platform configuration and attempt a database dump."""
        target_dest = dest_dir or (self.root_dir / "backups")
        target_dest.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        archive_name = f"backup_{timestamp}.tar.gz"
        archive_path = target_dest / archive_name

        with tarfile.open(archive_path, "w:gz") as tar:
            for file_name in ["platform.yaml", "versions.yaml", "compose.yaml"]:
                p = self.root_dir / file_name
                if p.exists():
                    tar.add(p, arcname=file_name)
            configs_dir = self.root_dir / "configs"
            if configs_dir.exists():
                tar.add(configs_dir, arcname="configs")

        # Attempt PostgreSQL database dump if container is running
        sql_dump_path: Path | None = None
        try:
            dump_path = target_dest / f"postgres_{timestamp}.sql"
            with open(dump_path, "w") as f:
                self.runner.exec(
                    self.root_dir,
                    "postgres",
                    ["pg_dumpall", "-U", "postgres"],
                    stdout=f,
                )
            sql_dump_path = dump_path
        except Exception:
            # Container might not be running; non-fatal
            pass

        return archive_path, sql_dump_path

    def restore_backup(self, src: Path) -> list[str]:
        """Restore configuration archive or SQL dump to the platform."""
        if not src.exists():
            raise FileNotFoundError(f"Backup source not found at {src}")

        restored_items: list[str] = []
        if src.is_file() and str(src).endswith((".tar.gz", ".tgz", ".tar")):
            with tarfile.open(src, "r:*") as tar:
                tar.extractall(path=self.root_dir)
            restored_items.append(f"archive:{src.name}")
        elif src.is_dir():
            for item in src.glob("*"):
                if item.name.endswith(".sql"):
                    with open(item) as f:
                        self.runner.exec(
                            self.root_dir,
                            "postgres",
                            ["psql", "-U", "postgres"],
                            stdin=f,
                        )
                    restored_items.append(f"sql:{item.name}")
        elif src.is_file() and src.name.endswith(".sql"):
            with open(src) as f:
                self.runner.exec(
                    self.root_dir,
                    "postgres",
                    ["psql", "-U", "postgres"],
                    stdin=f,
                )
            restored_items.append(f"sql:{src.name}")
        else:
            raise ValueError(f"Unsupported backup source format: {src}")

        return restored_items
