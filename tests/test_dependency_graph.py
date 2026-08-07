from platform.config import ServiceManifest, resolve_dependency_order

import pytest


def test_dependency_resolution_simple() -> None:
    services = {
        "a": ServiceManifest(name="a", image="img_a", version_key="a", depends_on=["b"]),
        "b": ServiceManifest(name="b", image="img_b", version_key="b"),
    }
    order = resolve_dependency_order(services, ["a", "b"])
    assert order == ["b", "a"]


def test_dependency_resolution_circular() -> None:
    services = {
        "a": ServiceManifest(name="a", image="img_a", version_key="a", depends_on=["b"]),
        "b": ServiceManifest(name="b", image="img_b", version_key="b", depends_on=["a"]),
    }
    with pytest.raises(ValueError, match="Circular dependency detected"):
        resolve_dependency_order(services, ["a", "b"])
