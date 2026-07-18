#!/bin/bash

# Runtime phase (runs as node user): initialize firewall, seed Hermes home,
# load secrets, write .env + shell-env files for the gateway.

initialize_firewall() {
  if [ "${FIREWALL_ENABLED:-true}" = "true" ]; then
    echo "Initializing firewall..."
    sudo --preserve-env=FIREWALL_MODULES,GH_TOKEN,HOST_GH_TOKEN \
      /usr/local/bin/init-firewall.sh
  fi
}

bootstrap_hermes_home() {
  HERMES_HOME="${HERMES_HOME:-/home/node/.hermes}"
  export HERMES_HOME
  COPILOT_HOME="${COPILOT_HOME:-/home/node/.copilot}"
  export COPILOT_HOME

  mkdir -p "$HERMES_HOME"/{cron,sessions,logs,memories,skills,hooks,skins,plans,workspace,home}
  mkdir -p "$COPILOT_HOME"

  chmod g+rX "$HERMES_HOME" 2>/dev/null || true
  find "$HERMES_HOME/sessions" -type d -exec chmod g+rX {} + 2>/dev/null || true

  # Hash-stamp the seeded config so rebuilds of .devcontainer/hermes-config.yaml
  # are picked up automatically while still preserving any per-agent edits made
  # directly to the runtime file.
  local default_path=/usr/local/share/hermes-defaults/config.yaml.default
  local runtime_path="$HERMES_HOME/config.yaml"
  local stamp_path="$HERMES_HOME/.config.yaml.seeded-hash"
  local default_hash
  default_hash=$(sha256sum "$default_path" | cut -d' ' -f1)

  if [ ! -f "$runtime_path" ]; then
    echo "Seeding Hermes config from default template..."
    cp "$default_path" "$runtime_path"
    echo "$default_hash" > "$stamp_path"
  elif [ -f "$stamp_path" ]; then
    local seeded_hash runtime_hash
    seeded_hash=$(cat "$stamp_path")
    runtime_hash=$(sha256sum "$runtime_path" | cut -d' ' -f1)
    if [ "$runtime_hash" = "$seeded_hash" ] && [ "$default_hash" != "$seeded_hash" ]; then
      echo "Refreshing Hermes config from updated default template..."
      cp "$default_path" "$runtime_path"
      echo "$default_hash" > "$stamp_path"
    elif [ "$runtime_hash" != "$seeded_hash" ] && [ "$default_hash" != "$seeded_hash" ]; then
      echo "WARN: $runtime_path has local edits AND the baked default has changed; not auto-updating." >&2
      echo "      diff $default_path $runtime_path  to merge manually." >&2
    fi
  fi

  if [ -n "${HERMES_SOUL_PATH:-}" ] && [ -f "$HERMES_SOUL_PATH" ]; then
    if [ ! "$HERMES_SOUL_PATH" -ef "$HERMES_HOME/SOUL.md" ]; then
      cp "$HERMES_SOUL_PATH" "$HERMES_HOME/SOUL.md"
    fi
  elif [ -f "$WORKSPACE_ROOT/.devcontainer/SOUL.md" ]; then
    cp "$WORKSPACE_ROOT/.devcontainer/SOUL.md" "$HERMES_HOME/SOUL.md"
  elif [ ! -f "$HERMES_HOME/SOUL.md" ]; then
    echo "Seeding Hermes SOUL.md from default template..."
    cp /usr/local/share/hermes-defaults/SOUL.md.default "$HERMES_HOME/SOUL.md"
  fi
}

write_hermes_env_files() {
  local copilot_token
  local effective_gh_token="${GH_TOKEN:-${HOST_GH_TOKEN:-}}"

  emit_env_from_candidates() {
    local key="$1"
    local candidate
    local value
    shift
    for candidate in "$key" "$@"; do
      value="${!candidate:-}"
      if [ -n "$value" ]; then
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
          echo "WARN: Skipping $key because it contains a newline" >&2
          return 0
        fi
        printf '%s=%s\n' "$key" "$value"
        return 0
      fi
    done
  }

  {
    copilot_token="${COPILOT_GITHUB_TOKEN:-$effective_gh_token}"
    [ -n "$copilot_token" ] && echo "COPILOT_GITHUB_TOKEN=$copilot_token"
    [ -n "${OPENROUTER_API_KEY:-}" ] && echo "OPENROUTER_API_KEY=$OPENROUTER_API_KEY"
    [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
    [ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY"
    [ -n "${GEMINI_API_KEY:-}" ] && echo "GEMINI_API_KEY=$GEMINI_API_KEY"
    [ -n "${DEEPSEEK_API_KEY:-}" ] && echo "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY"
    [ -n "${SENTRY_DSN:-}" ] && echo "SENTRY_DSN=$SENTRY_DSN"

    [ -n "${DISCORD_BOT_TOKEN:-}" ] && echo "DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN"
    [ -n "${DISCORD_ALLOWED_USERS:-}" ] && echo "DISCORD_ALLOWED_USERS=$DISCORD_ALLOWED_USERS"
    [ -n "${DISCORD_HOME_CHANNEL:-}" ] && echo "DISCORD_HOME_CHANNEL=$DISCORD_HOME_CHANNEL"

    [ -n "$effective_gh_token" ] && echo "GH_TOKEN=$effective_gh_token"
    [ -n "${GITHUB_TOKEN:-}" ] && echo "GITHUB_TOKEN=$GITHUB_TOKEN"
  } > "$HERMES_HOME/.env"
  chmod 600 "$HERMES_HOME/.env"

  HERMES_ENV_PATH="$HERMES_HOME/.env" \
    HERMES_SHELL_ENV_PATH="$HERMES_HOME/.shell-env.sh" \
    python3 "${HERMES_ENTRYPOINT_ROOT:-/usr/local/share/hermes-entrypoint}/lib/config_overrides.py" write-shell-env

  if [ -f "$HERMES_HOME/.shell-env.sh" ]; then
    source "$HERMES_HOME/.shell-env.sh"
  fi
}

run_runtime_bootstrap() {
  if [ -f "${INSTALL_DIR}/venv/bin/activate" ]; then
    source "${INSTALL_DIR}/venv/bin/activate"
  fi
  initialize_firewall
  bootstrap_hermes_home
  write_hermes_env_files
}
