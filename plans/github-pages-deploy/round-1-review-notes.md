# Plan review notes — round-1-draft.md (structure & communication pass)

Reviewed cold, as the engineer who'd execute it, against the current state of `web/` (verified
line numbers, file contents, routes, project file) and `CLAUDE.md`/`PROGRESS.md`. This is the
structure/communication lane only — technical correctness of the Actions YAML, the rafgraph
redirect math, etc. is out of scope here and is covered by the parallel sanity-check pass.

All grounding claims I spot-checked against the repo were accurate: line numbers for the three
subpath bugs (`Home.razor:56`, `WorkflowDetail.razor:30`, `app.css:1`), the three `@page` routes,
the absence of `.github/`, `.sln`, and `global.json`, the `index.html` content (including the
commented-out service-worker registration and the no-cache meta tags), and the csproj's
`ServiceWorker` item pointing at files that don't exist. No factual drift found there.

## Issues

1. **Step 8's last bullet reads as an action item but isn't one.** (lines ~228–239, specifically
   line 239: "Update `PROGRESS.md` (per CLAUDE.md milestone conventions, only when asked for a
   milestone): add the live URL and the manual console steps that were done.") This sits inside
   a numbered "Implementation steps (in order)" list, under "Step 8: Commit, push, verify live,"
   alongside concrete do-this-now actions (make the commit, push, run six live checks). An
   implementer following the steps in order would reasonably treat this bullet the same way —
   update `PROGRESS.md` now — only to find the clause immediately voiding it ("only when asked
   for a milestone"). Since this plan is itself the trigger for doing the work, not for a
   milestone flush, the bullet is misleading by placement. It should be pulled out of the
   numbered step list and stated as a standalone note (e.g., under "Notes" or folded into the
   final report instructions), not as step 8's last action.

2. **Assumptions section contains an item that explicitly isn't an assumption.** (line 243:
   "(Verified, not assumed: `configure-pages@v6.0.0`'s `action.yml` declares a `base_path`
   output, documented as `"/my-repo"` or `""`.)") The section header is "Assumptions
   (unverified)." A reader skimming for what's still open/unconfirmed would expect every bullet
   under that heading to be a real unverified risk — but the first one announces itself as
   verified. That undercuts the heading's purpose as a place to find what still needs checking.
   This fact belongs in the "Grounding" section with the other verified claims (it's the same
   kind of claim as the action-version grounding in D3), not under "Assumptions."

3. **D2's resolution is left ambiguously open inside what reads as a closed decision.** (line 45:
   "The task asked for the standard redirect trick, and the redirect gives a 200.
   **If reviewers prefer minimalism, this is the fallback.** It's a one-line workflow change,
   with no `404.html` source file and no decoder.") Every other decision in the "Decisions"
   section picks one option and moves on, with rejected alternatives clearly marked rejected.
   D2 instead leaves a live conditional branch ("if reviewers prefer minimalism") inside the
   decision record itself, with no indication of who adjudicates that preference, when, or
   whether round-1 review (this pass, or the parallel sanity-check pass) is the moment that gets
   decided. Steps 2–3 do commit unconditionally to the rafgraph approach, so the plan is
   internally executable as written — but a reader of the Decisions section alone could
   reasonably wonder whether D2 is still pending input before the plan is final. Worth either
   removing the "if reviewers prefer" hedge (and just noting the simpler option as rejected, like
   the others) or explicitly stating this is a question for this review round to settle.

4. **Step 7's "apply the same sed" doesn't restate the actual command.** (line 222: "Apply the
   same `sed`, then stage the output under a subfolder so the subpath matches Pages:
   `mkdir -p <scratch>/site && cp -r <scratch>/publish/wwwroot <scratch>/site/workflow-engine`.")
   Step 4 gives the exact `sed` invocation verbatim, parameterized by `$BASE_PATH` from CI. Step
   7 asks the implementer to "apply the same sed" locally but doesn't give the literal command
   with the hardcoded value substituted in (`/workflow-engine` instead of `${BASE_PATH}`), nor
   say explicitly to run it before or after the `cp -r`. It's inferable from context (the
   grounding section already states the sed was "tested against that output and works," and the
   target path is established), but it's a step where the implementer has to reconstruct a
   command rather than copy one, unlike every other code-bearing step in the plan, which all
   give exact text. A one-line literal `sed` command here would remove the guess.

5. **Two different "tell the user" obligations with inconsistent delivery instructions.** Step 6
   ends with an explicit, strong instruction: "I can't do these steps for the user. The plan's
   final report must list them explicitly" (line 217). Separately, the Risks section's
   service-worker bullet says only "Flag it to the user; don't fix it here" (line 254), with no
   statement of *when* or *where* that flag surfaces — in the final report alongside Step 6's
   items, during execution, or elsewhere. Since the Risks section is read before the numbered
   steps and isn't cross-referenced from Step 8's live-check list, an implementer who executes
   steps 1–8 mechanically could complete the whole plan and report back listing only Step 6's
   manual items (which are explicitly required), while the service-worker misleading-comment
   risk — also explicitly meant to reach the user — never makes it into that final report. The
   plan would be more robust if it consolidated everything that must reach the user into one
   place (e.g., a single "final report must include" checklist covering both Step 6's items and
   the service-worker flag), rather than splitting the obligation across two sections with
   different phrasing and different implied mechanisms.

6. **Minor: Step 3's placement instruction is underspecified given the real file.** (line 109:
   "Put it in `<head>`, after `<base>` and before any app script.") The current `index.html` has
   no script tags in `<head>` except an empty `<script type="importmap"></script>` near the end
   of `<head>`, with several unrelated `<link>`/`<meta>` tags in between. "Before any app script"
   doesn't actually constrain anything here (the importmap tag is empty and arguably isn't "an
   app script" in the sense meant), so two implementers could reasonably place the decoder
   snippet in different spots in `<head>` — immediately after `<base>`, or just before
   `</head>` — while both satisfying the letter of the instruction. Low severity since it
   probably doesn't affect behavior, but a precise anchor (e.g., "immediately after the `<base>`
   line") would remove the guess.

## Summary

Six issues found, all in the clarity/structure lane — none are "this step is wrong" findings,
and none block execution: an implementer could get through the whole plan without hitting a
hard stop. The most worth fixing before building are #1 (a step-list bullet that contradicts
itself) and #5 (the split, inconsistently-worded obligation to surface things to the user),
since both create a real chance that something slips through on an otherwise-correct run of the
plan. #2–#4 are small clarity/labeling fixes. #6 is cosmetic. I would not call this plan in need
of a full extra draft — these are polish-pass fixes, not structural rework.
