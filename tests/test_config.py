from pathlib import Path
from platform.config import load_platform_config, resolve_platform

import pytest


def test_load_platform_config(tmp_path: Path) -> None:
    platform_file = tmp_path / "platform.yaml"
    platform_file.write_text("""
name: test-platform
domain: test.internal
default_model: qwen
inference:
  host: 127.0.0.1
  port: 8080
network: test-net
services:
  - postgres
""")
    config = load_platform_config(tmp_path)
    assert config.name == "test-platform"
    assert config.domain == "test.internal"
    assert config.inference.host == "127.0.0.1"


def test_resolve_platform_real_repo() -> None:
    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)
    assert resolved.config.name == "xynotech-ai-platform"
    assert len(resolved.dependency_order) == 6
    assert "postgres" in resolved.services
    assert "caddy" in resolved.services


def test_resolve_platform_missing_manifest(tmp_path: Path) -> None:
    (tmp_path / "platform.yaml").write_text("""
name: test
domain: test.internal
inference:
  host: 127.0.0.1
  port: 8080
network: test
services:
  - non_existent_service
""")
    (tmp_path / "versions.yaml").write_text("""
platform: "0.1.0"
services: {}
""")
    with pytest.raises(ValueError, match="Missing service manifests"):
        resolve_platform(tmp_path)
