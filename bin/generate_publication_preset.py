#!/usr/bin/env python3
"""Generate the container preset's package allowlist from its catalog."""

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the allowlist needs regeneration")
    args = parser.parse_args()
    catalog = json.loads((ROOT / "publication/catalog.json").read_text())
    preset_path = ROOT / "publication-age-containers.json"
    preset = json.loads(preset_path.read_text())
    rules = [rule for rule in preset["packageRules"]
             if rule.get("overrideDatasource") == "custom.nip-publication"]
    if len(rules) != 1:
        raise SystemExit("Expected exactly one container publication datasource rule.")
    if not isinstance(catalog, dict) or not catalog:
        raise SystemExit("Publication catalog must be a nonempty package mapping.")
    packages = sorted(catalog)
    if rules[0].get("matchPackageNames") == packages:
        return
    if args.check:
        raise SystemExit("Publication allowlist is stale; run python3 bin/generate_publication_preset.py")
    rules[0]["matchPackageNames"] = packages
    preset_path.write_text(json.dumps(preset, indent=2) + "\n")


if __name__ == "__main__":
    main()
