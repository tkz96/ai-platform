import socket
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
PORTS_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "ports.sh"
UI_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "ui.sh"
STATE_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "state.sh"


def run_ports_func(
    code: str, env_vars: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    env_export = " ".join([f'export {k}="{v}";' for k, v in (env_vars or {}).items()])
    script = f"""
    export PROJECT_ROOT="{PROJECT_ROOT}"
    source "{UI_LIB}"
    source "{STATE_LIB}"
    source "{PORTS_LIB}"
    {env_export}
    {code}
    """
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True)


def test_port_available_on_free_port():
    # Find an unused port
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        free_port = s.getsockname()[1]

    res = run_ports_func(f"port_available {free_port} && echo 'free' || echo 'in_use'")
    assert res.returncode == 0
    assert "free" in res.stdout.strip()


def test_port_available_on_occupied_port():
    # Bind an unused port and hold it open
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        busy_port = s.getsockname()[1]

        res = run_ports_func(f"port_available {busy_port} && echo 'free' || echo 'in_use'")
        assert res.returncode == 0
        assert "in_use" in res.stdout.strip()


def test_port_find_available():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        busy_port = s.getsockname()[1]

        res = run_ports_func(f"port_find_available {busy_port}")
        assert res.returncode == 0
        found_port = int(res.stdout.strip())
        assert found_port > busy_port


def test_port_resolve_conflict_noninteractive(tmp_path: Path):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        busy_port = s.getsockname()[1]

        env = {
            "PROJECT_ROOT": str(tmp_path),
            "NONINTERACTIVE": "1",
        }
        res = run_ports_func(
            f'port_resolve_conflict "test_service" {busy_port} "test_service"',
            env_vars=env,
        )
        assert res.returncode == 0
        assert "using alternative port" in res.stdout or "using alternative port" in res.stderr


def test_bootstrap_help_includes_reset():
    res = subprocess.run(
        ["bash", str(PROJECT_ROOT / "bootstrap.sh"), "help"],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0
    assert "reset" in res.stdout
    assert "factory-reset" in res.stdout or "Full factory reset" in res.stdout


def test_factory_reset_cleans_state(tmp_path: Path):
    # Setup mock state in tmp_path
    state_dir = tmp_path / "state"
    secrets_dir = tmp_path / "secrets"
    state_dir.mkdir(parents=True)
    secrets_dir.mkdir(parents=True)
    (state_dir / "nodes.yaml").write_text("nodes: {}")
    (secrets_dir / "token").write_text("test")
    (tmp_path / ".env").write_text("TEST=1")
    (tmp_path / ".install-state").write_text("done")

    # Run run_factory_reset inside a subshell with mocked PROJECT_ROOT
    script = f"""
    export PROJECT_ROOT="{tmp_path}"
    export NONINTERACTIVE=1
    source "{UI_LIB}"
    source "{STATE_LIB}"
    source "{PORTS_LIB}"
    source "{PROJECT_ROOT / "scripts" / "install" / "lib" / "podman.sh"}"
    source "{PROJECT_ROOT / "scripts" / "install" / "lib" / "networking.sh"}"

    # Extract run_factory_reset definition from bootstrap.sh
    eval "$(sed -n '/run_factory_reset() {{/,/^}}/p' "{PROJECT_ROOT / "bootstrap.sh"}")"
    run_factory_reset --force
    """
    res = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert res.returncode == 0
    assert not (state_dir / "nodes.yaml").exists()
    assert not (secrets_dir / "token").exists()
    assert not (tmp_path / ".env").exists()
    assert not (tmp_path / ".install-state").exists()


def test_factory_reset_noninteractive_requires_force(tmp_path: Path):
    script = f"""
    export PROJECT_ROOT="{tmp_path}"
    export NONINTERACTIVE=1
    source "{UI_LIB}"
    source "{STATE_LIB}"
    source "{PORTS_LIB}"
    source "{PROJECT_ROOT / "scripts" / "install" / "lib" / "podman.sh"}"
    source "{PROJECT_ROOT / "scripts" / "install" / "lib" / "networking.sh"}"

    eval "$(sed -n '/run_factory_reset() {{/,/^}}/p' "{PROJECT_ROOT / "bootstrap.sh"}")"
    run_factory_reset
    """
    res = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert res.returncode == 1
    assert (
        "Nuclear factory reset requires interactive confirmation or --force" in res.stdout
        or "Nuclear factory reset requires interactive confirmation or --force" in res.stderr
    )
