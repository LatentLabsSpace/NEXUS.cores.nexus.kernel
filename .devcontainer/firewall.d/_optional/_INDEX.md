<!-- auto-index -->
# INDEX

> Universal optional firewall allowlists — selected per module by FIREWALL_KERNEL_MODULES (default: all); a DNS resolution failure only logs a warning and continues

## Files
| Name | Description |
|------|-------------|
| `anthropic.conf` | Anthropic API — Claude Code and hermes' anthropic provider (moved from `_required/`) |
| `anthropic-telemetry.conf` | Claude Code telemetry (Sentry, Statsig) — degrades harmlessly when unreachable |
| `fireworks.conf` | Fireworks AI API, console, and gRPC gateway used by firectl |
| `linear.conf` | Linear API |
| `mise.conf` | mise runtime manager download endpoint and Python package registries (PyPI) |
| `openai.conf` | OpenAI API, sign-in, and ChatGPT Codex backend — used by the Codex CLI |
| `vscode.conf` | VS Code extension marketplace and update service domains |
