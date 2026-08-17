from pathlib import Path
from platform.config import resolve_platform
from platform.renderer import generate_compose_dict, render_all


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
    from platform.config import ServiceManifest

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
