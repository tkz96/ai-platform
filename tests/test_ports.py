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
