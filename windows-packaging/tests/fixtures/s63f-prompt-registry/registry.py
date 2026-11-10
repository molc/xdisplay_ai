"""从 Settings 解析各 Agent 的激活 prompt 版本。"""

from __future__ import annotations

import hashlib
from pathlib import Path

from app.config import Settings, get_settings
from app.prompts.loader import load_meta_yaml

_PROMPTS_ROOT = Path(__file__).resolve().parent


def parse_prompt_versions(raw: str) -> dict[str, str]:
    """解析形如 `planner:v1.0,clarifier:v1.0,diagnoser:v1.0,explainer:v1.0` 的字符串。"""
    out: dict[str, str] = {}
    for part in raw.split(","):
        p = part.strip()
        if not p:
            continue
        if ":" not in p:
            continue
        agent, version = p.split(":", 1)
        out[agent.strip()] = version.strip()
    return out


def default_prompt_version_table() -> dict[str, str]:
    return parse_prompt_versions(str(Settings.model_fields["prompt_versions"].default))


def validate_prompt_version_pins(settings: Settings | None = None) -> list[str]:
    """founding case `trace_a1fca2831b59`：`.env` 整表覆写缺已注册 agent ⇒ turn 中段 `resolve_prompt_version` KeyError。"""
    cfg = settings or get_settings()
    effective = parse_prompt_versions(cfg.prompt_versions)
    problems: list[str] = []
    for agent in default_prompt_version_table():
        if agent not in effective:
            problems.append(
                f"生效 prompt_versions 缺已注册 agent {agent!r}"
                "（.env 整表覆写缺行？）"
            )
    for agent, version in effective.items():
        agent_dir = _PROMPTS_ROOT / agent
        if not agent_dir.is_dir():
            problems.append(f"prompt_versions 含无目录的 agent {agent!r}（stale 行？）")
        elif not (agent_dir / f"{version}.md").exists():
            problems.append(
                f"agent {agent!r} 钉扎版本 {version!r} 无文件 {agent}/{version}.md"
            )
        elif (mismatch := _digest_mismatch(agent_dir, version)):
            problems.append(mismatch)
    if problems:
        raise RuntimeError(
            "prompt 钉扎表启动校验失败（Story 24-68）：\n- "
            + "\n- ".join(problems)
            + f"\n生效表: {cfg.prompt_versions!r}"
        )
    return sorted(
        entry.name
        for entry in _PROMPTS_ROOT.iterdir()
        if entry.is_dir()
        and entry.name not in effective
        and any(entry.glob("v*.md"))
    )


def _digest_mismatch(agent_dir: Path, version: str) -> str:
    """A pinned prompt whose meta records its sha256 must still be those bytes."""
    meta_path = agent_dir / f"{version}.meta.yaml"
    recorded = load_meta_yaml(meta_path).get("sha256") if meta_path.exists() else None
    if not recorded:
        return ""
    actual = hashlib.sha256((agent_dir / f"{version}.md").read_bytes()).hexdigest()
    if actual == recorded:
        return ""
    return f"agent {agent_dir.name!r} 钉扎版本 {version!r} 内容与 meta sha256 不符（{actual}）"


def resolve_prompt_version(agent: str, settings: Settings | None = None) -> str:
    """返回某个 agent 当前激活版本（默认读 `XDISPLAY_AI_PROMPT_VERSIONS`）。"""
    cfg = settings or get_settings()
    versions = parse_prompt_versions(cfg.prompt_versions)
    if agent not in versions:
        msg = f"未配置 agent={agent!r} 的 prompt 版本: {cfg.prompt_versions!r}"
        raise KeyError(msg)
    return versions[agent]
