"""Runtime helpers for the Hermes entrypoint.

Invoked by the bash phases as:

    python3 /usr/local/share/hermes-entrypoint/lib/config_overrides.py <command>

Each subcommand reads its inputs from environment variables and edits the
on-disk Hermes `config.yaml` in place. Values are emitted via ``json.dumps``
so any embedded quotes / backslashes / unicode produce valid YAML scalars.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path


def _config_path() -> str:
    return os.environ["HERMES_HOME"] + "/config.yaml"


def _read_config() -> str:
    with open(_config_path()) as f:
        return f.read()


def _write_config(content: str) -> None:
    with open(_config_path(), "w") as f:
        f.write(content)


def _upsert_block_key(block: str, key: str, value: str) -> str:
    """Insert or replace ``  <key>: <value>`` inside a 2-space-indented YAML block."""
    pattern = rf"^  {re.escape(key)}:.*$"
    replacement = f"  {key}: {json.dumps(value)}"
    if re.search(pattern, block, re.MULTILINE):
        return re.sub(
            pattern, lambda _m: replacement, block, count=1, flags=re.MULTILINE
        )
    if block and not block.endswith("\n"):
        block += "\n"
    return block + replacement + "\n"


def _upsert_top_level_block(top_key: str, updates: dict[str, str]) -> None:
    if not updates:
        return
    content = _read_config()
    block_match = re.search(
        rf"^{re.escape(top_key)}:\n((?:^  .*(?:\n|$))*)", content, re.MULTILINE
    )
    if block_match:
        body = block_match.group(1)
        for key, value in updates.items():
            body = _upsert_block_key(body, key, value)
        content = (
            content[: block_match.start()]
            + f"{top_key}:\n"
            + body
            + content[block_match.end() :]
        )
    else:
        new_lines = [f"{top_key}:"]
        for key, value in updates.items():
            new_lines.append(f"  {key}: {json.dumps(value)}")
        content = "\n".join(new_lines) + "\n" + content
    _write_config(content)


def apply_model() -> None:
    provider = os.environ.get("HERMES_PROVIDER_VALUE", "")
    model = os.environ.get("HERMES_MODEL_VALUE", "")
    updates: dict[str, str] = {}
    if provider:
        updates["provider"] = provider
    if model:
        updates["default"] = model
    _upsert_top_level_block("model", updates)


def set_terminal_cwd() -> None:
    workspace_root = os.environ["WORKSPACE_ROOT_VALUE"]
    _upsert_top_level_block("terminal", {"cwd": workspace_root})


def configure_skills() -> None:
    skills_base = os.environ["SKILLS_BASE"]
    hermes_skills = os.environ["HERMES_SKILLS_VALUE"]

    if hermes_skills == "none":
        dirs: list[str] = []
    elif hermes_skills == "all":
        dirs = [skills_base] if os.path.isdir(skills_base) else []
    else:
        names = [s.strip() for s in hermes_skills.split(",") if s.strip()]
        dirs = [
            os.path.join(skills_base, n)
            for n in names
            if os.path.isdir(os.path.join(skills_base, n))
        ]
        missing = [n for n in names if not os.path.isdir(os.path.join(skills_base, n))]
        if missing:
            print(
                "Warning: HERMES_EXTERNAL_SKILLS — unknown categories skipped: "
                + ", ".join(missing)
            )

    # Kernel-resident skills (the kernel submodule's plugin-standard skills/
    # directory). Appended AFTER the workspace dirs so on a name collision the
    # harness's first-seen-wins rule lets a consumer's workspace skill shadow
    # the kernel's. Included whenever external skills aren't disabled outright;
    # HERMES_KERNEL_SKILLS=0 opts out. An absent directory (submodule not
    # initialized, or a pre-skills kernel pin) warns and skips — never fails
    # the boot; the next boot after the submodule appears picks it up.
    kernel_dir = os.environ.get("KERNEL_SKILLS_DIR", "")
    kernel_enabled = os.environ.get("HERMES_KERNEL_SKILLS", "1") != "0"
    if hermes_skills != "none" and kernel_enabled and kernel_dir:
        if os.path.isdir(kernel_dir):
            dirs.append(kernel_dir)
        else:
            print(
                "Warning: kernel skills dir absent (submodule not initialized, "
                "or kernel pin predates skills/): " + kernel_dir
            )

    if dirs:
        new_ed = (
            "  external_dirs:\n"
            + "\n".join(f"    - {json.dumps(d)}" for d in dirs)
            + "\n"
        )
    else:
        new_ed = "  external_dirs: []\n"

    # Surgical patch: only replace the external_dirs entry inside the existing
    # skills: block. Rebuilding the whole block clobbers sibling keys like
    # disabled: / platform_disabled: that the user set in hermes-config.yaml.
    content = _read_config()
    skills_match = re.search(
        r"^skills:\n((?:^  .*(?:\n|$))*)", content, re.MULTILINE
    )
    ed_pattern = re.compile(
        r"^  external_dirs:[^\n]*\n(?:^    -[^\n]*\n)*", re.MULTILINE
    )
    if skills_match:
        body = skills_match.group(1)
        if ed_pattern.search(body):
            body = ed_pattern.sub(new_ed, body, count=1)
        else:
            body = new_ed + body
        content = (
            content[: skills_match.start()]
            + "skills:\n"
            + body
            + content[skills_match.end() :]
        )
    else:
        content = content.rstrip("\n") + "\n\nskills:\n" + new_ed

    _write_config(content)
    print(f"skills.external_dirs = {dirs}")


def write_shell_env() -> None:
    from dotenv import dotenv_values

    env_path = Path(os.environ["HERMES_ENV_PATH"])
    shell_env_path = Path(os.environ["HERMES_SHELL_ENV_PATH"])
    hermes_venv_bin = os.environ.get(
        "HERMES_VENV_BIN", "/home/node/hermes-agent/venv/bin"
    )

    lines = [
        "#!/usr/bin/env bash",
        'case ":${PATH}:" in',
        "  *:/opt/mise/shims:*) ;;",
        '  *) export PATH="/opt/mise/shims:${PATH}" ;;',
        "esac",
        'case ":${PATH}:" in',
        f"  *:{hermes_venv_bin}:*) ;;",
        f'  *) export PATH="{hermes_venv_bin}:${{PATH}}" ;;',
        "esac",
    ]
    for key, value in dotenv_values(env_path).items():
        if not key or value is None:
            continue
        lines.append(f"export {key}={shlex.quote(value)}")

    shell_env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    shell_env_path.chmod(0o600)


_COMMANDS = {
    "apply-model": apply_model,
    "set-terminal-cwd": set_terminal_cwd,
    "configure-skills": configure_skills,
    "write-shell-env": write_shell_env,
}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in _COMMANDS:
        print(
            f"usage: {argv[0]} <{ '|'.join(_COMMANDS) }>",
            file=sys.stderr,
        )
        return 2
    _COMMANDS[argv[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
