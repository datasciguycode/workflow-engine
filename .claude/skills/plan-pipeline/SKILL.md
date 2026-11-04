---
name: plan-pipeline
description: Runs a multi-agent pipeline (plan-writer, plan-reviewer, sanity-check, architect-review) with a draft/revise loop to turn a feature/task description into a vetted implementation plan. Use when the user asks for a thorough or reviewed implementation plan, wants a plan "run through the pipeline," or invokes /plan-pipeline.
---

# Plan pipeline

Produces a vetted implementation plan for a task by running it through four expert agents,
each looking at the plan from a deliberately different, orthogonal lens, with a draft/revise
loop between the writer and the two review lenses before the architect's final pass:

- `plan-writer` (Opus) — **synthesis.** Drafts the plan from the task and the codebase, then
  revises it when review feedback comes back, round after round if needed.
- `plan-reviewer` (Sonnet) — **structural/communication lens.** Is the draft complete,
  internally consistent, unambiguous, and executable by someone who didn't write it?
- `sanity-check` (Sonnet) — **substance lens.** Is the draft correct and feasible — and
  beyond that, is each step the right call at all? It critiques, proposes concrete
  alternatives, and argues for cutting steps that shouldn't be built.
- `architect-review` (Opus) — **systemic lens + adjudication.** Does the final-round plan fit
  the existing architecture, and how should any remaining reviewer/sanity-check disagreement
  be resolved?

`plan-reviewer` and `sanity-check` each look only at the current draft — not at each other's
output — so their findings are genuinely independent, not one anchored on the other. They run
in parallel, every round. `architect-review` only runs once, at the end of the loop, and is
the only stage that sees both.

**You (the agent reading this skill) are the orchestrator.** Do not delegate orchestration to
another subagent — you call each stage yourself, in this same turn, respecting the
dependencies above (parallel only where nothing depends on the other), and you decide when the
loop ends. Each stage is a fresh agent (`subagent_type` set to the agent name below) with no
memory of this conversation, so every call must be fully self-contained: it does not know the
task, the codebase, or what prior rounds found unless you put it in the prompt or point it at
a file to read.

The four agent definitions live in `.claude/agents/`: `plan-writer.md`, `plan-reviewer.md`,
`sanity-check.md`, `architect-review.md`. Read them if you want their exact brief; you don't
need to in order to run this skill, just call them by name.

## File layout

All output lands in `plans/<slug>/` in the repo (not the scratchpad), named by round so the
whole trail stays readable:

```
plans/<slug>/round-1-draft.md
plans/<slug>/round-1-review-notes.md
plans/<slug>/round-1-sanity-check.md
plans/<slug>/round-2-draft.md          (only if round 1 needed a revision)
plans/<slug>/round-2-review-notes.md
plans/<slug>/round-2-sanity-check.md
...
plans/<slug>/final-plan.md             (architect-review's output, once)
```

## Steps

1. **Set up.** Pick a short kebab-case slug from the task description (e.g.
   `github-pages-deploy`). Create `plans/<slug>/` (`mkdir -p`). Set `round = 1`.

2. **Draft (plan-writer, Opus).** Call `Agent` with `subagent_type: "plan-writer"`.
   - Round 1: give it the full task description verbatim, point it at the project context to
     read (at minimum `CLAUDE.md` and `PROGRESS.md`, plus anything else you already know is
     relevant), and tell it to write to `plans/<slug>/round-1-draft.md`.
   - Round 2+ (revision): point it at the *previous* round's draft and both of that round's
     review files, and tell it to write the revised draft to `plans/<slug>/round-<N>-draft.md`.

3. **Review (plan-reviewer and sanity-check, in parallel, both Sonnet).** Both depend only on
   this round's draft, not on each other, so send both `Agent` calls in the same message:
   - `subagent_type: "plan-reviewer"` — read `plans/<slug>/round-<N>-draft.md` and the project
     context, write to `plans/<slug>/round-<N>-review-notes.md`.
   - `subagent_type: "sanity-check"` — read `plans/<slug>/round-<N>-draft.md` (**not** the
     reviewer's notes — its findings must be independent) and the project context, write to
     `plans/<slug>/round-<N>-sanity-check.md`.

   Wait for both before moving on.

4. **Decide: revise or advance.** Read both files' verdicts.
   - **Revise** if the plan-reviewer says the plan needs another draft, *or* sanity-check says
     something is severe enough to block the plan as written. Increment `round` and go back to
     step 2, in revision mode, *unless* `round` has already reached the cap (default **3**
     drafts total, i.e. up to 2 revisions — raise it if the user asked for more rigor, but say
     so). If the cap is hit with findings still outstanding, advance anyway and say so plainly
     when you report back.
   - **Advance** to step 5 once a round comes back with nothing blocking from either lens.

5. **Architect review (Opus), once.** Call `Agent` with `subagent_type: "architect-review"`.
   Point it at the final round's draft and both of that round's review files (not every
   historical round — the draft already incorporates earlier rounds' resolved feedback) plus
   the project context, and tell it to write the final plan and verdict to
   `plans/<slug>/final-plan.md`.

6. **Report back.** Read `plans/<slug>/final-plan.md` yourself. Tell the user: how many rounds
   it took, the verdict (`approved` / `approved-with-changes` / `needs-rework`), and — in your
   own words, not pasted — the one or two things most worth their attention before
   implementation starts. Point them at `plans/<slug>/` for the full trail. Do not start
   implementing the plan unless they ask you to.

## Notes

- If the task description is vague, it's fine to tighten it up yourself before round 1 rather
  than passing ambiguity straight to the writer — but say what you clarified.
- "Expert in all technologies being implemented" is each agent's own job per their brief, not
  something you need to spell out further — your prompts just need to tell them what context
  to read and where to read/write files.
- The loop is between the writer and the two review lenses only. `architect-review` doesn't
  send the plan back for another round — it adjudicates whatever's left and signs off (or
  says `needs-rework`, which is a verdict for the user, not another automatic loop iteration).
- This pipeline is for planning only. It never edits code outside `plans/<slug>/`.
