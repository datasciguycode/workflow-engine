# Progress

- Status (2026-11-08): dev is live and working, same as always — Blazor WASM app on GitHub
  Pages (`https://datasciguycode.github.io/workflow-engine/`), backed by Supabase (cloud
  project `workflow-engine-test`, ref `utwyvtbzesswpoihmlic`). Google OAuth sign-in works
  end to end.
- **Pending push to dev — 4 local commits, all held back deliberately** (dev has had an
  active test session; redeploying mid-session was avoided throughout 2026-11-07):
  `390fc11` (PROGRESS.md refresh), `a608106` (Chat-button header centering fix + the prod
  plan trail), `d25ce87` (PROGRESS.md: prod stood up), `3c181a1` (page-root overflow-x fix +
  a plan note update). Push all four whenever it's safe to redeploy dev — nothing here is
  unfinished, just queued.
- **Production exists** as a separate repo + Supabase project, stood up and actively
  iterated on 2026-11-07/08. Full plan and history: `plans/prod-instance-setup/final-plan.md`
  in this repo (that plan directory only lives here, not in the prod repo). Prod's own
  `PROGRESS.md` (in `/home/mmcbride/micah/claude/workflow-app-prod`) has its current status.
  Summary: repo `datasciguycode/workflow-engine-prod`, live at
  `https://datasciguycode.github.io/workflow-engine-prod/`, Supabase project
  `workflow-engine-prod` (ref `tapguiosrjbdusqyhxqe`), account "Falcon Auto and
  Performance." Verified working end to end (sign-in, chat, stage transitions, isolation).
- **Real bug found and fixed in prod's `agent-loop`, not yet ported to dev:** with the full
  unscoped conversation history, the agent could write a new value onto a different,
  more-recently-discussed job instead of the one actually open in the UI (caught via live
  testing 2026-11-07). Fixed with three changes, all live on prod only:
  1. `item_id` made optional on `move_stage`/`update_data`/`add_note`; the server (not the
     model) resolves it to the job open in the UI when omitted.
  2. The system prompt's reminder of which job is open is now much more forceful and
     includes the job's stable number.
  3. The list of *other* jobs is only sent to the agent when no job is open — while one is
     drilled into, the agent has zero visibility into any other job, closing off future
     name-collision risk (e.g. two different customers both named "Bob") at the source
     rather than relying on the model to disambiguate correctly every time.
  **This fix needs porting to dev's `supabase/functions/agent-loop/index.ts`** — same bug
  exists there, just unconfirmed/untriggered so far.
- **Other prod-only additions not yet ported to dev:**
  - A stable, permanent "Job #N" number (ranked by creation order, shown throughout the UI),
    replacing the old display-order numbering that shifted as jobs got touched.
  - An "Other Appointments" list on the Scheduling stage view (next 10 other jobs with a
    `scheduled_at`, date/title stacked, excludes the job being viewed).
  - Per-job Claude conversation scoping (one message history per job instead of one for the
    whole session) — bounds token cost per request to just the open job's own activity.
  - A Notes section on the job overview page, reading back every `add_note` call (previously
    write-only) — plus a soft nudge in the prompt: past 5 messages in one job+stage, the
    agent is told to prefer `add_note` over continuing to just talk about something.
  - An `agent_events` table (prod-only migration, not yet ported here) logging per-call
    token usage and tool/loop errors — gives real cost visibility instead of guessing.
- **Already applied to THIS repo's database directly** (infra, not app code, so no commit
  needed): `alter default privileges in schema public revoke all on tables from anon,
  authenticated;` — this project has (had) a platform-level Postgres default that granted
  `anon`/`authenticated` full privileges on any newly-created table automatically (caught
  when prod's new `agent_events` table came in wide open despite its migration only granting
  `select, insert`; this repo's existing tables already had their own grants manually
  corrected at some point in the past — same root cause, never fixed at the source until
  now). Future tables in both this project and prod's now start locked down by default. RLS
  was never actually bypassable either way; this just removes a recurring manual-fix step.
- **Deferred follow-ups** (full detail in `plans/prod-instance-setup/final-plan.md` →
  "Out of scope (deliberate)"): an admin UI for accounts/members, photo-to-field extraction
  (e.g. VIN from a photo), an upcoming-appointments list on the intake screen (separate from
  the Scheduling-stage one already built), making the prod repo private (needs GitHub Pro),
  an Anthropic spend alert (Console-side, not code), and job assignment/claiming (including
  at intake time) for multiple workers sharing one account's job queue.
- Outstanding: nothing uncommitted in either repo. Dev has 4 commits not yet pushed (see
  above, held back deliberately). Prod is fully committed and pushed, live, and working.
