from pathlib import Path

import yaml
from pydantic import BaseModel, Field


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
    health: HealthCheck | None = None


class VersionsConfig(BaseModel):
    platform: str
    services: dict[str, str]


class InferenceConfig(BaseModel):
    host: str
    port: int


class PlatformConfig(BaseModel):
    name: str
    domain: str
    default_model: str = "qwen2.5-coder"
    inference: InferenceConfig
    network: str
    services: list[str]


class ResolvedPlatform(BaseModel):
    config: PlatformConfig
    versions: VersionsConfig
    services: dict[str, ServiceManifest]
    dependency_order: list[str]


def load_platform_config(root_dir: Path) -> PlatformConfig:
    config_path = root_dir / "platform.yaml"
    if not config_path.exists():
        raise FileNotFoundError(f"Platform config not found at {config_path}")
    raw = yaml.safe_load(config_path.read_text())
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
    config = load_platform_config(root_dir)
    versions = load_versions(root_dir)
    services_dir = root_dir / "services"
    all_manifests = load_all_service_manifests(services_dir)
    return validate_platform(config, versions, all_manifests, env_vars=env_vars)
