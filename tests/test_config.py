from pathlib import Path

import pytest
from pydantic import ValidationError

from ai_platform.config import (
    InferenceConfig,
    PlatformConfig,
    ServiceManifest,
    VersionsConfig,
    load_platform_config,
    resolve_platform,
    validate_platform,
)


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


def test_validate_platform_pure() -> None:
    config = PlatformConfig(
        name="pure-platform",
        domain="pure.internal",
        inference=InferenceConfig(host="127.0.0.1", port=8080),
        network="pure-net",
        services=["svc_a"],
    )
    versions = VersionsConfig(platform="0.1.0", services={"v_a": "1.0.0"})
    manifests = {"svc_a": ServiceManifest(name="svc_a", image="img_a", version_key="v_a")}

    resolved = validate_platform(config, versions, manifests)
    assert resolved.config.name == "pure-platform"
    assert resolved.dependency_order == ["svc_a"]


def test_inference_config_validation() -> None:
    # Valid config
    inf = InferenceConfig(
        host="10.42.0.2",
        bind_host="10.42.0.2",
        port=8080,
        health_endpoint="/health",
        protocol="http",
        service_user="ubuntu",
        working_directory="/home/ubuntu",
        binary_path="/usr/local/bin/llama-server",
        model_path="/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf",
        extra_args=["--fit", "on"],
    )
    assert inf.host == "10.42.0.2"
    assert inf.bind_host == "10.42.0.2"
    assert inf.port == 8080
    assert inf.service_user == "ubuntu"
    assert inf.working_directory == "/home/ubuntu"
    assert inf.binary_path == "/usr/local/bin/llama-server"
    assert inf.model_path == "/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf"
    assert inf.extra_args == ["--fit", "on"]

    # Invalid port
    with pytest.raises(ValidationError):
        InferenceConfig(port=99999)
    with pytest.raises(ValidationError):
        InferenceConfig(port=0)

    # Invalid health endpoint (must start with /)
    with pytest.raises(ValidationError):
        InferenceConfig(health_endpoint="health")

    # Invalid protocol
    with pytest.raises(ValidationError):
        InferenceConfig(protocol="ftp")  # type: ignore


def test_env_override_precedence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "platform.yaml").write_text("""
name: test-platform
domain: test.internal
inference:
  host: 10.42.0.2
  bind_host: 10.42.0.2
  port: 8080
  health_endpoint: /health
  protocol: http
  service_user: ubuntu
  working_directory: /home/ubuntu
  binary_path: /usr/local/bin/llama-server
  model_path: /models/qwen.gguf
services: []
""")

    # 1. Base YAML defaults
    cfg1 = load_platform_config(tmp_path)
    assert cfg1.inference.host == "10.42.0.2"
    assert cfg1.inference.port == 8080
    assert cfg1.inference.service_user == "ubuntu"
    assert cfg1.inference.model_path == "/models/qwen.gguf"

    # 2. .env file override
    (tmp_path / ".env").write_text("""
INFERENCE_HOST=10.42.0.10
INFERENCE_PORT=8090
INFERENCE_MODEL_PATH=/env/models/qwen.gguf
INFERENCE_SERVICE_USER=ai-runner
""")
    cfg2 = load_platform_config(tmp_path)
    assert cfg2.inference.host == "10.42.0.10"
    assert cfg2.inference.port == 8090
    assert cfg2.inference.model_path == "/env/models/qwen.gguf"
    assert cfg2.inference.service_user == "ai-runner"

    # 3. os.environ overrides .env
    monkeypatch.setenv("INFERENCE_HOST", "10.42.0.20")
    monkeypatch.setenv("INFERENCE_PORT", "9000")
    monkeypatch.setenv("INFERENCE_MODEL_PATH", "/os/models/qwen.gguf")
    cfg3 = load_platform_config(tmp_path)
    assert cfg3.inference.host == "10.42.0.20"
    assert cfg3.inference.port == 9000
    assert cfg3.inference.model_path == "/os/models/qwen.gguf"

    # 4. Explicit env_vars dict overrides os.environ
    cfg4 = load_platform_config(
        tmp_path,
        env_vars={
            "INFERENCE_HOST": "10.42.0.30",
            "INFERENCE_MODEL_PATH": "/runtime/models/qwen.gguf",
        },
    )
    assert cfg4.inference.host == "10.42.0.30"
    assert cfg4.inference.port == 9000
    assert cfg4.inference.model_path == "/runtime/models/qwen.gguf"


def test_stdlib_platform_import() -> None:
    """Ensure standard library platform imports without collision with ai_platform."""
    import platform as stdlib_platform

    assert hasattr(stdlib_platform, "system")
    assert hasattr(stdlib_platform, "machine")
    assert hasattr(stdlib_platform, "python_version")
    assert stdlib_platform.__name__ == "platform"
    assert "ai_platform" not in getattr(stdlib_platform, "__file__", "")
