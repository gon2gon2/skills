#!/usr/bin/env python3
"""Fail if a plugin's Claude and Codex versions disagree.

For every plugins/<name>/, compares the version in .claude-plugin/plugin.json,
.codex-plugin/plugin.json and the plugin's entry in .claude-plugin/marketplace.json.

    python3 scripts/check_plugin_versions.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> int:
    marketplace = {p["name"]: p for p in load(ROOT / ".claude-plugin/marketplace.json")["plugins"]}
    errors = []
    for plugin_dir in sorted((ROOT / "plugins").iterdir()):
        if not plugin_dir.is_dir():
            continue
        name = plugin_dir.name
        versions = {}
        for kind in ("claude", "codex"):
            manifest = plugin_dir / f".{kind}-plugin/plugin.json"
            if manifest.exists():
                versions[str(manifest.relative_to(ROOT))] = load(manifest).get("version")
        if name in marketplace:
            versions[".claude-plugin/marketplace.json"] = marketplace[name].get("version")
        if len(set(versions.values())) > 1:
            lines = "\n".join(f"  {path}: {version}" for path, version in versions.items())
            errors.append(f"{name}: versions differ\n{lines}")
        else:
            print(f"{name}: {next(iter(versions.values()), 'no manifests')}")
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
