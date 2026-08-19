.PHONY: help render install status verify update backup restore destroy ui lint format test

help:
	@echo "AI Platform Makefile commands:"
	@echo "  make render    - Validate platform configuration and render templates & compose.yaml"
	@echo "  make install   - Render configuration and deploy platform containers"
	@echo "  make status    - Check health status of all platform services"
	@echo "  make verify    - Validate config schema and run health checks"
	@echo "  make update    - Pull latest container images and redeploy"
	@echo "  make backup    - Backup platform database and configuration state"
	@echo "  make restore   - Restore platform state"
	@echo "  make destroy   - Stop and remove all containers, networks, and volumes"
	@echo "  make ui        - Start Control Plane Web UI dashboard server"
	@echo "  make lint      - Run ruff and yamllint code format checks"
	@echo "  make format    - Format Python code with ruff"
	@echo "  make test      - Run automated pytest suite"

render:
	uv run python bootstrap.py render

install:
	uv run python bootstrap.py install

status:
	uv run python bootstrap.py status

verify:
	uv run python bootstrap.py verify

update:
	uv run python bootstrap.py update

backup:
	uv run python bootstrap.py backup

restore:
	uv run python bootstrap.py restore

destroy:
	uv run python bootstrap.py destroy

ui:
	uv run uvicorn ai_platform.web.app:app --host 127.0.0.1 --port 8888

lint:
	uv run ruff check .
	uv run ruff format --check .
	uv run yamllint .

format:
	uv run ruff format .

test:
	uv run pytest
