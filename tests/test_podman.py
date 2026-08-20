import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
PODMAN_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "podman.sh"
UI_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "ui.sh"


def run_podman_func(
    code: str, env_vars: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    env_export = " ".join([f'export {k}="{v}";' for k, v in (env_vars or {}).items()])
    script = f"""
    export PROJECT_ROOT="{PROJECT_ROOT}"
    source "{UI_LIB}"
    source "{PODMAN_LIB}"
    {env_export}
    {code}
    """
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True)


def test_podman_machine_exists_nonexistent():
    res = run_podman_func("podman_machine_exists 'nonexistent-vm-test' && echo 'yes' || echo 'no'")
    assert res.returncode == 0
    assert res.stdout.strip() == "no"


def test_podman_machine_running_nonexistent():
    res = run_podman_func("podman_machine_running 'nonexistent-vm-test' && echo 'yes' || echo 'no'")
    assert res.returncode == 0
    assert res.stdout.strip() == "no"


def test_podman_machine_recover_stale_command(tmp_path: Path):
    log_file = tmp_path / "mock.log"
    res = run_podman_func(
        f"""
        podman() {{
            echo "mock podman: $*" >> "{log_file}"
            return 0
        }}
        podman_machine_recover_stale 'test-stale-vm'
        """
    )
    assert res.returncode == 0
    assert "Removing stale or corrupted Podman machine 'test-stale-vm'" in res.stdout
    assert log_file.exists()
    log_content = log_file.read_text()
    assert "mock podman: system connection rm test-stale-vm" in log_content
    assert "mock podman: system connection rm test-stale-vm-root" in log_content
    assert "mock podman: machine rm -f test-stale-vm" in log_content


def test_podman_machine_init_handles_stale_recovery(tmp_path: Path):
    # Simulate: first init fails with 'already exists', inspect fails (stale), then rm -f and second init succeeds
    count_file = tmp_path / "init_count"
    count_file.write_text("0")
    res = run_podman_func(
        f"""
        podman() {{
            if [[ "$1" == "machine" && "$2" == "inspect" ]]; then
                # Stale machine: inspect fails
                return 1
            elif [[ "$1" == "machine" && "$2" == "init" ]]; then
                local cnt
                cnt=$(cat "{count_file}")
                cnt=$((cnt + 1))
                echo "$cnt" > "{count_file}"
                if (( cnt == 1 )); then
                    echo "Error: test-vm: already exists" >&2
                    return 125
                else
                    echo "Machine initialized successfully"
                    return 0
                fi
            elif [[ "$1" == "machine" && "$2" == "rm" ]]; then
                return 0
            fi
            return 0
        }}
        podman_machine_init "test-vm" 4 8192 60
        """
    )
    assert res.returncode == 0
    assert "stale/inconsistent state. Recovering" in res.stdout
    assert "initialized after recovery" in res.stdout


def test_podman_machine_start_handles_stale_recovery(tmp_path: Path):
    # Simulate: machine start fails with 'VM does not exist', recovers and recreates
    count_file = tmp_path / "start_count"
    count_file.write_text("0")
    res = run_podman_func(
        f"""
        podman() {{
            if [[ "$1" == "machine" && "$2" == "inspect" ]]; then
                local cnt
                cnt=$(cat "{count_file}")
                if (( cnt == 0 )); then
                    return 1
                fi
                echo '[{{"State": "running"}}]'
                return 0
            elif [[ "$1" == "machine" && "$2" == "list" ]]; then
                local cnt
                cnt=$(cat "{count_file}")
                if (( cnt == 0 )); then
                    echo ""
                else
                    echo "test-vm Currently running"
                fi
                return 0
            elif [[ "$1" == "machine" && "$2" == "start" ]]; then
                local cnt
                cnt=$(cat "{count_file}")
                cnt=$((cnt + 1))
                echo "$cnt" > "{count_file}"
                if (( cnt == 1 )); then
                    echo "Error: test-vm: VM does not exist" >&2
                    return 125
                else
                    return 0
                fi
            elif [[ "$1" == "machine" && "$2" == "rm" ]]; then
                return 0
            elif [[ "$1" == "machine" && "$2" == "init" ]]; then
                return 0
            elif [[ "$1" == "info" ]]; then
                return 0
            fi
            return 0
        }}
        podman_machine_start "test-vm" 4 8192 60
        """
    )
    assert res.returncode == 0
    assert "Recovering stale machine" in res.stdout
    assert "is running and responsive" in res.stdout
