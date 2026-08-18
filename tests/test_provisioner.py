from pathlib import Path
from platform.provisioner import provision_all_nodes

PROJECT_ROOT = Path(__file__).parent.parent


def test_provision_all_nodes_handles_offline_gracefully():
    # If no nodes exist or offline nodes exist, provision_all_nodes should return dict without throwing unhandled exceptions
    results = provision_all_nodes(PROJECT_ROOT)
    assert isinstance(results, dict)
