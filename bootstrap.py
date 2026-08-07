from pathlib import Path

import yaml

ROOT = Path(__file__).parent

versions = yaml.safe_load((ROOT / "versions.yaml").read_text())

platform = yaml.safe_load((ROOT / "platform.yaml").read_text())

print("Platform:", platform["name"])

for name, info in versions["services"].items():
    print(f"{name}: {info['version']}")
