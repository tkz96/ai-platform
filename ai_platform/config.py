import os
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, Field, field_validator


class PortMapping(BaseModel):
    host_port: int
    container_port: int
    protocol: str = "tcp"


class VolumeMount(BaseModel):
    source: str
    target: str
    mode: str = "rw"


class HealthCheck(BaseModel):
    endpoint: str | None = None
    command: list[str] | None = None
    interval: str = "10s"
    timeout: str = "5s"
    retries: int = 3


class ServiceManifest(BaseModel):
    name: str
    image: str
    version_key: str
    ports: list[PortMapping] = Field(default_factory=list)
    volumes: list[VolumeMount] = Field(default_factory=list)
    environment: list[str] = Field(default_factory=list)
    env_file: list[str] = Field(default_factory=list)
    depends_on: list[str] = Field(default_factory=list)
    command: list[str] | str | None = None
    health: HealthCheck | None = None


class VersionsConfig(BaseModel):
    platform: str
    services: dict[str, str]


class InferenceConfig(BaseModel):
    host: str = Field(default="10.42.0.2", min_length=1)
    bind_host: str = Field(default="10.42.0.2", min_length=1)
    port: int = Field(default=8080, ge=1, le=65535)
    health_endpoint: str = Field(default="/health", pattern=r"^/.*")
    protocol: Literal["http", "https"] = "http"
    service_user: str = Field(default="ubuntu", min_length=1)
    working_directory: str = Field(default="/home/ubuntu", min_length=1)
    binary_path: str = Field(default="/usr/local/bin/llama-server", min_length=1)
    model_path: str = Field(
        default="/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf",
        min_length=1,
    )
    extra_args: list[str] = Field(
        default_factory=lambda: [
            "--fit",
            "on",
            "-fa",
            "on",
            "-ctk",
            "q4_0",
            "-ctv",
            "q4_0",
            "-c",
            "32768",
            "-t",
            "14",
            "-cnv",
        ]
    )

    @field_validator("extra_args", mode="before")
    @classmethod
    def validate_extra_args(cls, v: Any) -> Any:
        if isinstance(v, str):
            return v.split()
        return v


class NetworkConfig(BaseModel):
    name: str = "ai-platform"
    subnet: str = "10.42.0.0/24"
    mac_ip: str = "10.42.0.1"
    node_ip_start: str = "10.42.0.2"
    node_pool_size: int = 8
    dhcp_pool_start: str = "10.42.0.100"
    dhcp_pool_end: str = "10.42.0.200"
    probe_image: str = (
        "docker.io/curlimages/curl@sha256:"
        "c3b8bee303c6c6beed656cfc921218c529d65aa61114eb9e27c62047a1271b9b"
    )


class PlatformConfig(BaseModel):
    name: str
    domain: str
    default_model: str = "qwen3.6-35b-a3b"
    inference: InferenceConfig = Field(default_factory=InferenceConfig)
    network: NetworkConfig = Field(default_factory=NetworkConfig)
    services: list[str]

    @field_validator("network", mode="before")
    @classmethod
    def validate_network(cls, v: Any) -> Any:
        if isinstance(v, str):
            return NetworkConfig(name=v)
        return v


class ResolvedPlatform(BaseModel):
    config: PlatformConfig
    versions: VersionsConfig
    services: dict[str, ServiceManifest]
    dependency_order: list[str]


ENV_OVERRIDES: dict[str, tuple[str, ...]] = {
    "INFERENCE_HOST": ("inference", "host"),
    "INFERENCE_BIND_HOST": ("inference", "bind_host"),
    "INFERENCE_PORT": ("inference", "port"),
    "INFERENCE_HEALTH_ENDPOINT": ("inference", "health_endpoint"),
    "INFERENCE_PROTOCOL": ("inference", "protocol"),
    "INFERENCE_SERVICE_USER": ("inference", "service_user"),
    "INFERENCE_WORKING_DIRECTORY": ("inference", "working_directory"),
    "INFERENCE_BINARY_PATH": ("inference", "binary_path"),
    "INFERENCE_MODEL_PATH": ("inference", "model_path"),
    "INFERENCE_EXTRA_ARGS": ("inference", "extra_args"),
    "PLATFORM_DOMAIN": ("domain",),
}


def _parse_dotenv(env_path: Path) -> dict[str, str]:
    """Parse a simple KEY=VALUE .env file without external dependencies."""
    result: dict[str, str] = {}
    if not env_path.exists():
        return result
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip()
            # Strip surrounding quotes if present
            if len(val) >= 2 and (
                (val.startswith('"') and val.endswith('"'))
                or (val.startswith("'") and val.endswith("'"))
            ):
                val = val[1:-1]
            result[key] = val
    return result


def _apply_env_overrides(
    raw_config: dict[str, Any], effective_env: dict[str, str]
) -> dict[str, Any]:
    """Apply environment overrides to raw YAML dict based on ENV_OVERRIDES."""
    for env_key, path in ENV_OVERRIDES.items():
        if env_key in effective_env and effective_env[env_key] != "":
            val_str = effective_env[env_key]
            # Convert types appropriately
            target: dict[str, Any] = raw_config
            for part in path[:-1]:
                if part not in target or not isinstance(target[part], dict):
                    target[part] = {}
                target = target[part]

            leaf = path[-1]
            if leaf == "port":
                try:
                    target[leaf] = int(val_str)
                except ValueError:
                    target[leaf] = val_str
            elif leaf == "extra_args":
                target[leaf] = val_str.split() if isinstance(val_str, str) else val_str
            else:
                target[leaf] = val_str
    return raw_config


def load_platform_config(root_dir: Path, env_vars: dict[str, str] | None = None) -> PlatformConfig:
    config_path = root_dir / "platform.yaml"
    if not config_path.exists():
        raise FileNotFoundError(f"Platform config not found at {config_path}")
    raw = yaml.safe_load(config_path.read_text()) or {}

    # Precedence: platform.yaml defaults -> .env -> os.environ -> explicit env_vars
    effective_env = _parse_dotenv(root_dir / ".env")
    effective_env.update(dict(os.environ))
    if env_vars:
        effective_env.update(env_vars)

    raw = _apply_env_overrides(raw, effective_env)
    return PlatformConfig.model_validate(raw)


def load_versions(root_dir: Path) -> VersionsConfig:
    versions_path = root_dir / "versions.yaml"
    if not versions_path.exists():
        raise FileNotFoundError(f"Versions config not found at {versions_path}")
    raw = yaml.safe_load(versions_path.read_text())
    return VersionsConfig.model_validate(raw)


def load_service_manifest(manifest_path: Path) -> ServiceManifest:
    if not manifest_path.exists():
        raise FileNotFoundError(f"Service manifest not found at {manifest_path}")
    raw = yaml.safe_load(manifest_path.read_text())
    return ServiceManifest.model_validate(raw)


def load_all_service_manifests(services_dir: Path) -> dict[str, ServiceManifest]:
    manifests: dict[str, ServiceManifest] = {}
    if not services_dir.exists():
        return manifests
    for manifest_file in services_dir.glob("*.yaml"):
        service_name = manifest_file.stem
        manifests[service_name] = load_service_manifest(manifest_file)
    return manifests


def resolve_dependency_order(
    services: dict[str, ServiceManifest], enabled_services: list[str]
) -> list[str]:
    """Topologically sort services based on depends_on."""
    visited: set[str] = set()
    visiting: set[str] = set()
    order: list[str] = []

    def visit(node: str) -> None:
        if node in visiting:
            raise ValueError(f"Circular dependency detected involving service '{node}'")
        if node not in visited:
            visiting.add(node)
            if node in services:
                for dep in services[node].depends_on:
                    if dep in enabled_services:
                        visit(dep)
            visiting.remove(node)
            visited.add(node)
            order.append(node)

    for svc in enabled_services:
        visit(svc)

    return order


def validate_platform(
    config: PlatformConfig,
    versions: VersionsConfig,
    all_manifests: dict[str, ServiceManifest],
    env_vars: dict[str, str] | None = None,
) -> ResolvedPlatform:
    """Pure validation and resolution logic without filesystem I/O."""
    # 1. Validate enabled services have manifests
    missing_manifests = [s for s in config.services if s not in all_manifests]
    if missing_manifests:
        msg = f"Missing service manifests for enabled services: {', '.join(missing_manifests)}"
        raise ValueError(msg)

    enabled_manifests = {s: all_manifests[s] for s in config.services}

    # 2. Validate version keys exist in versions.yaml
    for s_name, manifest in enabled_manifests.items():
        if manifest.version_key not in versions.services:
            msg = (
                f"Service '{s_name}' references version_key "
                f"'{manifest.version_key}' which is missing in versions.yaml"
            )
            raise ValueError(msg)

    # 3. Validate dependencies exist in platform.yaml
    for s_name, manifest in enabled_manifests.items():
        for dep in manifest.depends_on:
            if dep not in config.services:
                msg = (
                    f"Service '{s_name}' depends on '{dep}', which is not enabled in platform.yaml"
                )
                raise ValueError(msg)

    # 4. Validate required environment variables if provided
    if env_vars is not None:
        missing_envs: list[str] = []
        for s_name, manifest in enabled_manifests.items():
            for req_env in manifest.environment:
                if req_env not in env_vars or not env_vars[req_env]:
                    missing_envs.append(f"{s_name}:{req_env}")
        if missing_envs:
            raise ValueError(f"Missing required environment variables: {', '.join(missing_envs)}")

    # 5. Resolve dependency graph
    dependency_order = resolve_dependency_order(enabled_manifests, config.services)

    return ResolvedPlatform(
        config=config,
        versions=versions,
        services=enabled_manifests,
        dependency_order=dependency_order,
    )


def resolve_platform(root_dir: Path, env_vars: dict[str, str] | None = None) -> ResolvedPlatform:
    config = load_platform_config(root_dir, env_vars=env_vars)
    versions = load_versions(root_dir)
    services_dir = root_dir / "services"
    all_manifests = load_all_service_manifests(services_dir)
    return validate_platform(config, versions, all_manifests, env_vars=env_vars)
