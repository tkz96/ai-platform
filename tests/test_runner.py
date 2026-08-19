from pathlib import Path
from unittest.mock import MagicMock, patch

from ai_platform.runner import ComposeRunner


def test_compose_runner_custom_bin(tmp_path: Path) -> None:
    runner = ComposeRunner(compose_bin=["custom", "compose"])
    assert runner.get_compose_cmd() == ["custom", "compose"]


@patch("subprocess.run")
def test_compose_runner_detection(mock_run: MagicMock) -> None:
    # Simulate podman compose succeeding
    mock_run.return_value.returncode = 0
    runner = ComposeRunner()
    cmd = runner.get_compose_cmd()
    assert cmd == ["podman", "compose"]


@patch("subprocess.run")
def test_compose_runner_up(mock_run: MagicMock, tmp_path: Path) -> None:
    runner = ComposeRunner(compose_bin=["podman", "compose"])
    runner.up(cwd=tmp_path)
    mock_run.assert_called_once_with(["podman", "compose", "up", "-d"], cwd=tmp_path, check=True)


@patch("subprocess.run")
def test_compose_runner_down(mock_run: MagicMock, tmp_path: Path) -> None:
    runner = ComposeRunner(compose_bin=["podman", "compose"])
    runner.down(cwd=tmp_path, volumes=True)
    mock_run.assert_called_once_with(["podman", "compose", "down", "-v"], cwd=tmp_path, check=True)


@patch("subprocess.run")
def test_compose_runner_pull(mock_run: MagicMock, tmp_path: Path) -> None:
    runner = ComposeRunner(compose_bin=["podman", "compose"])
    runner.pull(cwd=tmp_path)
    mock_run.assert_called_once_with(["podman", "compose", "pull"], cwd=tmp_path, check=True)


@patch("subprocess.run")
def test_compose_runner_exec(mock_run: MagicMock, tmp_path: Path) -> None:
    runner = ComposeRunner(compose_bin=["podman", "compose"])
    runner.exec(cwd=tmp_path, service="postgres", command=["pg_dumpall"])
    mock_run.assert_called_once_with(
        ["podman", "compose", "exec", "-T", "postgres", "pg_dumpall"],
        cwd=tmp_path,
        stdout=None,
        stderr=None,
        stdin=None,
        check=True,
    )
