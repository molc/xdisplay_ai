"""Fail the package build unless the image contains every declared runtime dependency."""

from __future__ import annotations

import importlib.metadata as metadata
import re
import tomllib
from pathlib import Path


def distribution_name(requirement: str) -> str:
    return re.split(r"[<>=!~\[]", requirement, maxsplit=1)[0].strip()


def main() -> None:
    project = tomllib.loads(Path("/app/pyproject.toml").read_text(encoding="utf-8"))
    missing: list[str] = []
    for requirement in project["project"]["dependencies"]:
        name = distribution_name(requirement)
        try:
            metadata.version(name)
        except metadata.PackageNotFoundError:
            missing.append(name)
    if missing:
        raise SystemExit("image is missing declared dependencies: " + ", ".join(missing))
    print("image_dependencies_ok", len(project["project"]["dependencies"]))


if __name__ == "__main__":
    main()
