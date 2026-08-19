"""AI Platform core package."""
from __future__ import annotations

import sys
import importlib.machinery
import importlib.util

# Forward standard library platform attributes so third-party dependencies (e.g. uvicorn)
# can access platform.system(), platform.machine(), etc. without collision.
try:
    _stdlib_paths = [p for p in sys.path if p and p != "/Users/ai-macmini/ai-platform" and not p.endswith("/ai-platform")]
    _spec = importlib.machinery.PathFinder.find_spec("platform", _stdlib_paths)
    if _spec and _spec.loader:
        _stdlib_mod = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_stdlib_mod)
        for _attr in dir(_stdlib_mod):
            if not _attr.startswith("__") and _attr not in globals():
                globals()[_attr] = getattr(_stdlib_mod, _attr)
except Exception:
    pass
