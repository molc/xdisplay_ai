#!/usr/bin/env python3
"""Run s63f validate_prompt_version_pins against a generated installer .env.

Does not import pydantic. Loads the real registry.py with a stub Settings object
and either the real s63f prompt tree or a synthetic tree of agent directories.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path
from types import ModuleType, SimpleNamespace


def parse_env_file(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        entries[key.strip()] = value
    return entries


def extract_default_prompt_versions(config_py: Path) -> str:
    text = config_py.read_text(encoding="utf-8")
    match = re.search(
        r"prompt_versions:\s*str\s*=\s*\((.*?)\)\s*\n\s*agent_runtime_timeout_seconds",
        text,
        re.S,
    )
    if not match:
        raise SystemExit(f"could not extract prompt_versions default from {config_py}")
    return "".join(re.findall(r'"([^"]*)"', match.group(1)))


def load_meta_yaml(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    match = re.search(r'(?m)^sha256:\s*["\']?([0-9a-fA-F]{64})', text)
    if not match:
        return {}
    return {"sha256": match.group(1).lower()}


def make_synthetic_prompts(root: Path, table: str) -> None:
    for part in table.split(","):
        part = part.strip()
        if not part or ":" not in part:
            continue
        agent, version = part.split(":", 1)
        agent = agent.strip()
        version = version.strip()
        if agent in {"PAGE_HTML", "STYLESHEET"}:
            continue
        agent_dir = root / agent
        agent_dir.mkdir(parents=True, exist_ok=True)
        (agent_dir / f"{version}.md").write_text(f"# {agent} {version}\n", encoding="utf-8")


def load_registry(registry_py: Path):
    app_pkg = ModuleType("app")
    config_mod = ModuleType("app.config")
    prompts_pkg = ModuleType("app.prompts")
    loader_mod = ModuleType("app.prompts.loader")

    class PlaceholderSettings:
        prompt_versions = ""
        model_fields = {"prompt_versions": SimpleNamespace(default="")}

    config_mod.Settings = PlaceholderSettings  # type: ignore[attr-defined]
    config_mod.get_settings = lambda: PlaceholderSettings()  # type: ignore[attr-defined]
    loader_mod.load_meta_yaml = load_meta_yaml  # type: ignore[attr-defined]
    sys.modules["app"] = app_pkg
    sys.modules["app.config"] = config_mod
    sys.modules["app.prompts"] = prompts_pkg
    sys.modules["app.prompts.loader"] = loader_mod

    source = registry_py.read_text(encoding="utf-8")
    namespace = {
        "__file__": str(registry_py.resolve()),
        "__name__": "app.prompts.registry",
    }
    exec(compile(source, str(registry_py), "exec"), namespace)
    return namespace


def make_settings_class(default_table: str):
    class Settings:
        model_fields = {"prompt_versions": SimpleNamespace(default=default_table)}

        def __init__(self, prompt_versions: str) -> None:
            self.prompt_versions = prompt_versions

    return Settings


def run_validation(
    *,
    env_path: Path,
    registry_py: Path,
    prompts_root: Path,
    default_table: str,
    expect: str,
) -> int:
    entries = parse_env_file(env_path)
    effective = entries.get("XDISPLAY_AI_PROMPT_VERSIONS", "")
    if not effective:
        raise SystemExit(f"{env_path} has no XDISPLAY_AI_PROMPT_VERSIONS assignment")

    namespace = load_registry(registry_py)
    namespace["_PROMPTS_ROOT"] = prompts_root.resolve()
    Settings = make_settings_class(default_table)
    namespace["Settings"] = Settings
    namespace["get_settings"] = lambda: Settings(effective)

    settings = Settings(effective)
    validate = namespace["validate_prompt_version_pins"]
    try:
        validate(settings)
        if expect == "fail":
            print(
                "FAIL: expected validate_prompt_version_pins to raise; table was accepted:",
                effective,
                file=sys.stderr,
            )
            return 1
        print("PASS: validate_prompt_version_pins accepted generated prompt_versions")
        return 0
    except RuntimeError as exc:
        if expect == "pass":
            print(f"FAIL: validate_prompt_version_pins rejected generated env:\n{exc}", file=sys.stderr)
            return 1
        message = str(exc)
        if "PAGE_HTML" not in message and "缺已注册 agent" not in message:
            print(f"FAIL: rejection did not match the a62 registry failure:\n{exc}", file=sys.stderr)
            return 1
        print("PASS: validate_prompt_version_pins rejected the truncated/stale table")
        return 0


def resolve_backend_source(explicit: str | None) -> Path | None:
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    env_value = __import__("os").environ.get("S63F_BACKEND_SOURCE", "").strip()
    if env_value:
        candidates.append(Path(env_value))
    candidates.extend(
        [
            Path("/tmp/s63f-src/ai_orchestration-s63f-dd6ab3d50"),
            Path("/opt/cursor/artifacts/ai_orchestration-s63f-dd6ab3d50"),
        ]
    )
    for candidate in candidates:
        registry = candidate / "app" / "prompts" / "registry.py"
        config_py = candidate / "app" / "config.py"
        if registry.is_file() and config_py.is_file():
            return candidate
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, type=Path)
    parser.add_argument("--expect", choices=("pass", "fail"), required=True)
    parser.add_argument("--backend-source", type=Path)
    parser.add_argument("--registry-py", type=Path)
    parser.add_argument("--prompts-root", type=Path)
    parser.add_argument("--default-table")
    parser.add_argument("--synthetic", action="store_true")
    args = parser.parse_args(argv)

    backend = resolve_backend_source(str(args.backend_source) if args.backend_source else None)
    registry_py = args.registry_py
    prompts_root = args.prompts_root
    default_table = args.default_table
    temp_root = None

    if backend is not None and not args.synthetic:
        registry_py = backend / "app" / "prompts" / "registry.py"
        prompts_root = backend / "app" / "prompts"
        default_table = extract_default_prompt_versions(backend / "app" / "config.py")
    else:
        if registry_py is None:
            raise SystemExit("missing --registry-py when no s63f backend source is available")
        if default_table is None:
            raise SystemExit("missing --default-table for synthetic validation")
        if prompts_root is None:
            temp_root = Path(tempfile.mkdtemp(prefix="s63f-prompt-dirs-"))
            prompts_root = temp_root
            make_synthetic_prompts(prompts_root, default_table)

    try:
        return run_validation(
            env_path=args.env,
            registry_py=registry_py,
            prompts_root=prompts_root,
            default_table=default_table,
            expect=args.expect,
        )
    finally:
        if temp_root is not None:
            import shutil

            shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
