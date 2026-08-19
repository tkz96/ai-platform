from pathlib import Path

from ai_platform.config import resolve_platform
from ai_platform.renderer import generate_compose_dict, render_all


def test_renderer_real_repo() -> None:
    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)
    compose_dict = generate_compose_dict(resolved)

    assert compose_dict["name"] == "xynotech-ai-platform"
    assert "postgres" in compose_dict["services"]
    assert "caddy" in compose_dict["services"]

    caddy_deps = compose_dict["services"]["caddy"]["depends_on"]
    assert caddy_deps["litellm"]["condition"] == "service_healthy"


def test_render_all(tmp_path: Path) -> None:
    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)
    rendered = render_all(repo_root, resolved)

    assert any("compose.yaml" in str(p) for p in rendered)
    assert (repo_root / "compose.yaml").exists()


def test_env_file_rendering() -> None:
    from ai_platform.config import ServiceManifest

    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)
    manifest = ServiceManifest(
        name="test_svc", image="img", version_key="litellm", env_file=[".env", ".env.local"]
    )
    resolved.services["test_svc"] = manifest
    resolved.dependency_order.append("test_svc")
    compose_dict = generate_compose_dict(resolved)
    assert compose_dict["services"]["test_svc"]["env_file"] == [".env", ".env.local"]


def test_litellm_template_rendering() -> None:
    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)
    render_all(repo_root, resolved)

    litellm_cfg = repo_root / "configs" / "litellm" / "config.yaml"
    assert litellm_cfg.exists()
    content = litellm_cfg.read_text()
    assert "api_base: http://10.42.0.2:8080/v1" in content


def test_litellm_rendering_multi_node(tmp_path: Path) -> None:
    from ai_platform.nodes import (
        ModelAssignment,
        NodeDesiredConfig,
        NodeIdentity,
        NodeRecord,
        NodeRegistry,
        NodeRuntimeState,
        save_registry,
    )

    repo_root = Path(__file__).parent.parent
    # Setup tmp_path with templates and platform config
    (tmp_path / "templates" / "litellm").mkdir(parents=True)
    template_src = repo_root / "templates" / "litellm" / "config.yaml.j2"
    (tmp_path / "templates" / "litellm" / "config.yaml.j2").write_text(template_src.read_text())

    (tmp_path / "services").mkdir(parents=True)
    (tmp_path / "services" / "litellm.yaml").write_text("""
name: litellm
image: ghcr.io/berriai/litellm
version_key: litellm
""")

    (tmp_path / "platform.yaml").write_text("""
name: test-platform
domain: test.internal
default_model: qwen3.6-35b-a3b
services:
  - litellm
""")
    (tmp_path / "versions.yaml").write_text("""
platform: "0.1.0"
services:
  litellm: "v1.0.0"
""")

    # Populate registry with 1 healthy node and 1 unhealthy node
    reg = NodeRegistry()
    reg.nodes["node-01"] = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="gpu-01",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
        ),
        desired=NodeDesiredConfig(
            models=[ModelAssignment(model_name="qwen3.6-35b-a3b", port=8080)]
        ),
        runtime=NodeRuntimeState(
            status="ready",
            http_healthy=True,
            systemd_active=True,
            active_model="qwen3.6-35b-a3b",
        ),
    )
    reg.nodes["node-02"] = NodeRecord(
        identity=NodeIdentity(
            id="node-02",
            hostname="gpu-02",
            mac_address="00:aa:bb:cc:dd:ee",
            reserved_ip="10.42.0.3",
        ),
        desired=NodeDesiredConfig(
            models=[ModelAssignment(model_name="deepseek-r1-32b", port=8080)]
        ),
        runtime=NodeRuntimeState(
            status="unhealthy",
            http_healthy=False,
            systemd_active=True,
        ),
    )
    save_registry(tmp_path, reg)

    resolved = resolve_platform(tmp_path)
    render_all(tmp_path, resolved)

    rendered_cfg = tmp_path / "configs" / "litellm" / "config.yaml"
    assert rendered_cfg.exists()
    content = rendered_cfg.read_text()
    assert "model_name: qwen3.6-35b-a3b" in content
    assert "api_base: http://10.42.0.2:8080/v1" in content
    # Unhealthy node-02 must NOT be rendered in LiteLLM config
    assert "deepseek-r1-32b" not in content
    assert "10.42.0.3" not in content


def test_llama_server_service_rendering() -> None:
    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)
    render_all(repo_root, resolved)

    service_file = repo_root / "configs" / "inference" / "llama-server.service"
    assert service_file.exists()
    content = service_file.read_text()
    assert "User=ubuntu" in content
    assert "WorkingDirectory=/home/ubuntu" in content
    assert "--host 10.42.0.2" in content
    assert "--port 8080" in content
    assert "--model /home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf" in content
    assert "--fit on -fa on -ctk q4_0 -ctv q4_0 -c 32768 -t 14 -cnv" in content


def test_llama_server_service_overrides(tmp_path: Path) -> None:
    # Setup minimal repo structure in tmp_path
    (tmp_path / "templates" / "inference").mkdir(parents=True)
    template_src = (
        Path(__file__).parent.parent / "templates" / "inference" / "llama-server.service.j2"
    )
    (tmp_path / "templates" / "inference" / "llama-server.service.j2").write_text(
        template_src.read_text()
    )

    (tmp_path / "platform.yaml").write_text("""
name: test-platform
domain: test.internal
services: []
inference:
  host: 10.42.0.2
  bind_host: 10.42.0.2
  port: 8080
""")
    (tmp_path / "versions.yaml").write_text("""
platform: "0.1.0"
services: {}
""")

    # Override via env_vars
    env_overrides = {
        "INFERENCE_BIND_HOST": "10.42.0.50",
        "INFERENCE_PORT": "8099",
        "INFERENCE_MODEL_PATH": "/custom/path/model.gguf",
        "INFERENCE_SERVICE_USER": "ai-runner",
        "INFERENCE_WORKING_DIRECTORY": "/opt/ai",
        "INFERENCE_EXTRA_ARGS": "--fit on -c 16384",
    }
    resolved = resolve_platform(tmp_path, env_vars=env_overrides)
    render_all(tmp_path, resolved)

    rendered_svc = tmp_path / "configs" / "inference" / "llama-server.service"
    assert rendered_svc.exists()
    content = rendered_svc.read_text()
    assert "User=ai-runner" in content
    assert "WorkingDirectory=/opt/ai" in content
    assert "--host 10.42.0.50" in content
    assert "--port 8099" in content
    assert "--model /custom/path/model.gguf" in content
    assert "--fit on -c 16384" in content


def test_systemd_escape() -> None:
    from ai_platform.renderer import systemd_escape

    # Ordinary flags and tokens (no escaping needed)
    assert systemd_escape("--fit") == "--fit"
    assert systemd_escape("on") == "on"
    assert systemd_escape("-fa") == "-fa"
    assert systemd_escape("/usr/local/bin/llama-server") == "/usr/local/bin/llama-server"

    # Empty string
    assert systemd_escape("") == '""'

    # Spaces in paths
    assert systemd_escape("/path/with spaces/model.gguf") == '"/path/with spaces/model.gguf"'
    assert systemd_escape("argument with spaces") == '"argument with spaces"'

    # Tabs
    assert systemd_escape("arg\twith\ttab") == '"arg\twith\ttab"'

    # Quotes
    assert systemd_escape('say "hello"') == '"say \\"hello\\""'

    # Backslashes
    assert systemd_escape(r"C:\Models\test.gguf") == '"C:\\\\Models\\\\test.gguf"'


def test_render_node_service_unit(tmp_path: Path) -> None:
    from ai_platform.nodes import (
        ModelAssignment,
        NodeDesiredConfig,
        NodeIdentity,
        NodeRecord,
        NodeRuntimeState,
    )
    from ai_platform.renderer import render_node_service_unit

    repo_root = Path(__file__).parent.parent
    resolved = resolve_platform(repo_root)

    node = NodeRecord(
        identity=NodeIdentity(
            id="node-01",
            hostname="gpu-pc-1",
            mac_address="00:11:22:33:44:55",
            reserved_ip="10.42.0.2",
            ssh_user="ubuntu",
        ),
        desired=NodeDesiredConfig(
            models=[
                ModelAssignment(
                    model_name="test-model",
                    model_path="/path/with spaces/model.gguf",
                    port=8080,
                    extra_args=["--fit", "on", "-c", "32768", "custom arg with space"],
                )
            ]
        ),
        runtime=NodeRuntimeState(status="enrolled"),
    )

    unit_content = render_node_service_unit(repo_root, resolved, node)
    assert "Description=AI Platform llama.cpp Inference Server (node-01)" in unit_content
    assert "User=ubuntu" in unit_content
    assert "--host 10.42.0.2" in unit_content
    assert "--port 8080" in unit_content
    assert '--model "/path/with spaces/model.gguf"' in unit_content
    assert '--fit on -c 32768 "custom arg with space"' in unit_content
