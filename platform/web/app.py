from __future__ import annotations

from pathlib import Path
from platform.web.routes.dashboard import router as dashboard_router

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

PROJECT_ROOT = Path(__file__).parent.parent.parent
static_dir = PROJECT_ROOT / "templates" / "web" / "static"
static_dir.mkdir(parents=True, exist_ok=True)

app = FastAPI(
    title="AI Platform Web UI",
    description="Control Plane & Inference Cluster Management Dashboard",
    version="0.1.0",
)

app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
app.include_router(dashboard_router)


def create_app() -> FastAPI:
    return app


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("platform.web.app:app", host="127.0.0.1", port=8888, reload=True)
