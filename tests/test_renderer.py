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
