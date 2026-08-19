import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
UI_LIB = PROJECT_ROOT / "scripts" / "install" / "lib" / "ui.sh"


def run_ui_sh(
    code: str, noninteractive: str | None = None, stdin_input: str | None = None
) -> subprocess.CompletedProcess[str]:
    env_str = f"export NONINTERACTIVE={noninteractive};" if noninteractive is not None else ""
    full_cmd = f"""
    {env_str}
    source "{UI_LIB}"
    {code}
    """
    return subprocess.run(
        ["bash", "-c", full_cmd],
        input=stdin_input,
        capture_output=True,
        text=True,
    )


def test_is_noninteractive_env_set():
    res = run_ui_sh("is_noninteractive && echo 'yes' || echo 'no'", noninteractive="1")
    assert res.returncode == 0
    assert "yes" in res.stdout.strip()


def test_ui_confirm_noninteractive_default_yes():
    res = run_ui_sh('ui_confirm "Continue?" "Y"', noninteractive="1")
    assert res.returncode == 0


def test_ui_confirm_noninteractive_default_no():
    res = run_ui_sh('ui_confirm "Continue?" "N"', noninteractive="1")
    assert res.returncode == 1


def test_ui_prompt_text_noninteractive():
    res = run_ui_sh('ui_prompt_text "Port" "8080"', noninteractive="1")
    assert res.returncode == 0
    assert res.stdout.strip() == "8080"


def test_ui_prompt_secret_noninteractive_fails():
    res = run_ui_sh('ui_prompt_secret "Password"', noninteractive="1")
    assert res.returncode == 1
    assert "Cannot prompt for secret in non-interactive mode" in res.stderr


def test_ui_recoverable_noninteractive_returns_nonzero():
    res = run_ui_sh('ui_recoverable "Error test" "Fix guidance"', noninteractive="1")
    assert res.returncode == 1
    assert "Problem Detected" in res.stdout
    assert "skipping retry prompt" in res.stdout


def test_ui_recovery_menu_noninteractive_returns_zero():
    res = run_ui_sh('ui_recovery_menu "Title" "Error" "Retry" "Skip" "Quit"', noninteractive="1")
    assert res.returncode == 0
    assert res.stdout.strip() == "0"
    assert "selecting default recovery action" in res.stderr


def test_ui_choice_noninteractive_returns_zero():
    res = run_ui_sh('ui_choice "Pick one" "Option A" "Option B"', noninteractive="1")
    assert res.returncode == 0
    assert res.stdout.strip() == "0"
    assert "selecting default choice" in res.stderr
