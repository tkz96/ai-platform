from pathlib import Path
from platform.lifecycle import PlatformLifecycle
from platform.runner import ComposeRunner
from unittest.mock import MagicMock

import pytest


def test_lifecycle_render_and_deploy(tmp_path: Path) -> None:
    repo_root = Path(__file__).parent.parent
    (tmp_path / "platform.yaml").write_text((repo_root / "platform.yaml").read_text())
    (tmp_path / "versions.yaml").write_text((repo_root / "versions.yaml").read_text())

    services_dir = tmp_path / "services"
    services_dir.mkdir()
    for f in (repo_root / "services").glob("*.yaml"):
        (services_dir / f.name).write_text(f.read_text())

    mock_runner = MagicMock(spec=ComposeRunner)
    lifecycle = PlatformLifecycle(tmp_path, runner=mock_runner)

    # Test render
    resolved, rendered = lifecycle.render()
    assert resolved.config.name == "xynotech-ai-platform"
    assert any("compose.yaml" in str(p) for p in rendered)

    # Test deploy
    deployed_files = lifecycle.deploy()
    assert any("compose.yaml" in str(p) for p in deployed_files)
    mock_runner.up.assert_called_once_with(tmp_path, detached=True)


def test_lifecycle_update_and_teardown(tmp_path: Path) -> None:
    repo_root = Path(__file__).parent.parent
    (tmp_path / "platform.yaml").write_text((repo_root / "platform.yaml").read_text())
    (tmp_path / "versions.yaml").write_text((repo_root / "versions.yaml").read_text())

    services_dir = tmp_path / "services"
    services_dir.mkdir()
    for f in (repo_root / "services").glob("*.yaml"):
        (services_dir / f.name).write_text(f.read_text())

    mock_runner = MagicMock(spec=ComposeRunner)
    lifecycle = PlatformLifecycle(tmp_path, runner=mock_runner)

    # Test update
    lifecycle.update()
    mock_runner.pull.assert_called_once_with(tmp_path)
    mock_runner.up.assert_called_once_with(tmp_path, detached=True)

    # Test teardown
    lifecycle.teardown(volumes=True)
    mock_runner.down.assert_called_once_with(tmp_path, volumes=True)


def test_lifecycle_backup_and_restore(tmp_path: Path) -> None:
    # Setup dummy repo files in tmp_path
    (tmp_path / "platform.yaml").write_text("name: test-platform")
    (tmp_path / "versions.yaml").write_text("platform: 1.0.0")
    (tmp_path / "compose.yaml").write_text("services: {}")
    (tmp_path / "configs" / "litellm").mkdir(parents=True)
    (tmp_path / "configs" / "litellm" / "config.yaml").write_text("model: test")

    mock_runner = MagicMock(spec=ComposeRunner)
    lifecycle = PlatformLifecycle(tmp_path, runner=mock_runner)

    # Test create_backup
    backup_dest = tmp_path / "custom_backups"
    archive_path, sql_dump = lifecycle.create_backup(dest_dir=backup_dest)
    assert archive_path.exists()
    assert str(archive_path).endswith(".tar.gz")

    # Test restore_backup from archive
    restore_target = tmp_path / "restored_repo"
    restore_target.mkdir()
    restore_lifecycle = PlatformLifecycle(restore_target, runner=mock_runner)
    restored_items = restore_lifecycle.restore_backup(archive_path)
    assert len(restored_items) > 0
    assert (restore_target / "platform.yaml").exists()
    assert (restore_target / "platform.yaml").read_text() == "name: test-platform"
    assert (restore_target / "configs" / "litellm" / "config.yaml").exists()


def test_lifecycle_restore_missing_file(tmp_path: Path) -> None:
    lifecycle = PlatformLifecycle(tmp_path)
    with pytest.raises(FileNotFoundError):
        lifecycle.restore_backup(tmp_path / "non_existent.tar.gz")
