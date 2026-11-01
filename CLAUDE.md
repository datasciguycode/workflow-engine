# Workflow Engine

## Milestones — flushing state before a context clear

A "milestone" is a specific, user-invoked request: run the final pass needed to safely
clear the context window (via `/clear` or a new session) without losing anything. Only run
this when the user actually asks for it — not automatically at the end of every response.

On request:

1. **Commit everything.** Run `git status` and `git diff` to see what's outstanding. Stage
   and commit all real work with a clear message describing what changed and why (not just
   what). If something is intentionally left uncommitted (e.g. a half-finished experiment),
   say so explicitly rather than silently leaving it.
2. **Update `PROGRESS.md`.** Keep it a lean current snapshot — status, what's working, and
   the next concrete step — not a running narrative. Trim anything that ballooned past that;
   detailed history belongs in commit messages and `git log`, not here.
3. **Report back** once done, confirming it's safe to clear. If something is genuinely not
   safe to lose (a decision still pending user confirmation, a local-only config change),
   say so explicitly instead of declaring the milestone complete.
