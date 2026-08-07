import sys
from pathlib import Path

repo_root = Path(__file__).parent.parent
platform_dir = str(repo_root / "platform")

if "platform" in sys.modules:
    mod = sys.modules["platform"]
    if not hasattr(mod, "__path__") or mod.__path__ is None:
        mod.__path__ = [platform_dir]
    elif platform_dir not in mod.__path__:
        mod.__path__.insert(0, platform_dir)
