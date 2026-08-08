import subprocess
from pathlib import Path
from typing import IO, Any


class ComposeRunner:
    """Encapsulates execution of compose commands
    (podman compose, podman-compose, docker compose).
    """

    def __init__(self, compose_bin: list[str] | None = None) -> None:
        self._compose_bin = compose_bin

    def get_compose_cmd(self) -> list[str]:
        if self._compose_bin is not None:
            return self._compose_bin

        for candidate in [["podman", "compose"], ["podman-compose"], ["docker", "compose"]]:
            try:
                res = subprocess.run(candidate + ["version"], capture_output=True)
                if res.returncode == 0:
                    self._compose_bin = candidate
                    return candidate
            except FileNotFoundError:
                pass

        default_cmd = ["podman", "compose"]
        self._compose_bin = default_cmd
        return default_cmd

    def up(self, cwd: Path, detached: bool = True) -> None:
        cmd = self.get_compose_cmd() + (["up", "-d"] if detached else ["up"])
        subprocess.run(cmd, cwd=cwd, check=True)

    def down(self, cwd: Path, volumes: bool = False) -> None:
        cmd = self.get_compose_cmd() + (["down", "-v"] if volumes else ["down"])
        subprocess.run(cmd, cwd=cwd, check=True)

    def pull(self, cwd: Path) -> None:
        cmd = self.get_compose_cmd() + ["pull"]
        subprocess.run(cmd, cwd=cwd, check=True)

    def exec(
        self,
        cwd: Path,
        service: str,
        command: list[str],
        stdout: IO[Any] | int | None = None,
        stderr: IO[Any] | int | None = None,
        stdin: IO[Any] | int | None = None,
    ) -> None:
        cmd = self.get_compose_cmd() + ["exec", "-T", service] + command
        subprocess.run(cmd, cwd=cwd, stdout=stdout, stderr=stderr, stdin=stdin, check=True)
