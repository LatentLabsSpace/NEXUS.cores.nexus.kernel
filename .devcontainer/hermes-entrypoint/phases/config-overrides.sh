#!/bin/bash

HERMES_CONFIG_OVERRIDES_PY="${HERMES_ENTRYPOINT_ROOT:-/usr/local/share/hermes-entrypoint}/lib/config_overrides.py"

apply_model_overrides() {
  if [ -z "${HERMES_PROVIDER:-}" ] && [ -z "${HERMES_MODEL:-}" ]; then
    return
  fi

  if [[ "${HERMES_PROVIDER:-}" == *$'\n'* || "${HERMES_PROVIDER:-}" == *$'\r'* ]]; then
    echo "Invalid HERMES_PROVIDER: newline characters are not allowed" >&2
    return 1
  fi
  if [[ "${HERMES_MODEL:-}" == *$'\n'* || "${HERMES_MODEL:-}" == *$'\r'* ]]; then
    echo "Invalid HERMES_MODEL: newline characters are not allowed" >&2
    return 1
  fi

  HERMES_PROVIDER_VALUE="${HERMES_PROVIDER:-}" \
    HERMES_MODEL_VALUE="${HERMES_MODEL:-}" \
    python3 "$HERMES_CONFIG_OVERRIDES_PY" apply-model

  local changes=()
  [ -n "${HERMES_PROVIDER:-}" ] && changes+=("model.provider=$HERMES_PROVIDER")
  [ -n "${HERMES_MODEL:-}" ] && changes+=("model.default=$HERMES_MODEL")
  echo "Set ${changes[*]}"
}

set_terminal_cwd() {
  if [[ "${WORKSPACE_ROOT:-}" == *$'\n'* || "${WORKSPACE_ROOT:-}" == *$'\r'* ]]; then
    echo "Invalid WORKSPACE_ROOT: newline characters are not allowed" >&2
    return 1
  fi

  WORKSPACE_ROOT_VALUE="${WORKSPACE_ROOT}" \
    python3 "$HERMES_CONFIG_OVERRIDES_PY" set-terminal-cwd

  printf 'Set terminal.cwd=%s\n' "$WORKSPACE_ROOT"
}

configure_external_skills() {
  local skills_base="${WORKSPACE_ROOT}/.claude/skills"
  local hermes_skills="${HERMES_EXTERNAL_SKILLS:-all}"

  SKILLS_BASE="$skills_base" \
    HERMES_SKILLS_VALUE="$hermes_skills" \
    python3 "$HERMES_CONFIG_OVERRIDES_PY" configure-skills
}

apply_runtime_config_overrides() {
  apply_model_overrides
  set_terminal_cwd
  configure_external_skills
}
