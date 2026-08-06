# cargo/ — working artifacts

What the repo carries rather than what it is: build output, scratch working
files, session workspaces, generated artifacts. Nothing here is a source of
truth — anything in `cargo/` should be reproducible from `codex/` + `atlas/`.

Treat this directory as disposable. If something here becomes load-bearing,
that is the signal to promote it into `codex/` (if it is code) or `atlas/` (if
it is knowledge).

Add ignore rules for this tree as its contents take shape — the seed does not
ship a root `.gitignore`, since what counts as disposable is project-specific.
Keep those rules narrow enough that a genuinely useful artifact can still be
committed deliberately.
