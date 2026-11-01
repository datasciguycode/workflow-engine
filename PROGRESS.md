# Progress

- Status (2026-11-01): backend (Phases 0–4b) and the Blazor WASM UI are both built and
  working. Cloud Supabase project (`workflow-engine-test`) is fully wired end to end —
  real Google OAuth sign-in against the cloud-pointed app, verified live, including the
  chat/agent-loop path (create_item/move_stage/update_data/add_note via Claude tool use),
  which ran successfully end to end for the first time this session.
- Fixed this session (all now committed): (1) `public.*` tables had RLS policies but no
  matching `GRANT`s to `authenticated`, so every PostgREST call 403'd — added migration
  `20261101000000_grant_authenticated_table_access.sql`; (2) the `agent-loop` edge function
  had no CORS handling (no `OPTIONS` response, no `Access-Control-Allow-*` headers), which
  WebKit surfaces as an opaque `TypeError: Load failed` — fixed in
  `supabase/functions/agent-loop/index.ts`; (3) the `ANTHROPIC_API_KEY` Supabase secret was
  invalid — replaced with a working key (not stored in the repo).
- Next step: GitHub Pages deploy (Actions workflow, `base href` subpath, `404.html` SPA
  fallback).
- Outstanding: nothing uncommitted as of this milestone — see git log for the OAuth
  migration + infra-fix commit.
