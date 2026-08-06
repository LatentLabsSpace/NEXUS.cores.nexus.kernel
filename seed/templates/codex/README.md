# codex/ — code

Runnable code for {{SERVICE_PREFIX}}. Each project under here is
self-contained; a project's own `CLAUDE.md` is authoritative for work inside
it, and takes precedence over the repo-root conventions where they conflict.

Knowledge about the code (specs, design notes) lives in `atlas/`, not here.

## Rule of Two

Nothing lands in a shared/`packages/` directory until a **second** consumer
needs it. First implementations are born inside the project that needs them and
extracted only when a real second consumer exists. Do not create speculative
shared libraries.

This governs code, not standards: conventions are adopted repo-wide
immediately, because standards are cheap to adopt early and expensive to
retrofit, while shared code is the reverse.
