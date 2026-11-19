# Round-2 sanity check: Rideshare mileage + expense tracking

Scope: re-verify, on their own merits (not by trusting the draft's self-report), whether
round 2's three claimed fixes to round 1's blocking issues actually hold, and sanity-check what's
new in this revision. Verified against `plans/uber-mileage-tracker/round-2-draft.md`, the live
codebase facts it cites, and external sources (Cornell LII text of 26 CFR 1.274-5T, LocationIQ's
own help docs and pricing page, the OSM Nominatim usage policy). I did not read
`round-1-review-notes.md`, `round-1-sanity-check.md`, or any other review-notes file, per
instructions.

## Re-verification of the three round-1 blocking issues

**1. Regulation citation and substantiation story — fix holds.**
I fetched the actual Cornell LII text of 26 CFR 1.274-5T and located the aggregation-of-business-use
paragraph directly. It reads:

> `(C) Aggregation of business use. Uses which may be considered part of a single use, for
> example, a round trip or uninterrupted business use, may be accounted for by a single record.`

This is exactly `§1.274-5T(c)(6)(i)(C)`, and the plan's paraphrase ("allow an uninterrupted
business use to be recorded as a single use") is an accurate restatement, not a stretch. The
citation is correct. §9.1 still hedges this as unconfirmed ("I'm only moderately confident... haven't
read the current eCFR paragraph text") — that hedge can now be dropped; it's confirmed. Minor,
not blocking, but worth a one-line update before this goes in a migration header as settled fact
rather than an open assumption.

The substantiation reframing itself (shift log + platform trip-history export as the two halves of
one record) is sound reasoning and is no longer buried: it's in the TL;DR (§0.2), stated as a
requirement in the §3 table, surfaced as a static tip in the capture UI (Step 6f), and surfaced
again as a `note` field on both Report pages (Step 2, Step 6g). That's four independent places a
driver would see it, which resolves the "buried note" objection from round 1.

**2. `platform` required — fix holds, and the UX edge cases are actually handled, not just
asserted.** I checked the SQL directly rather than trusting the prose: in Step 2's migration,
`platform` is in the Start stage's `checklist` and is **not** in `optional_checklist`
(`["start_area"]` only). Combined with the verified codebase fact that `DoneNextStage` (Complete
Stage) only renders once every `checklist − optional_checklist` key is non-null, this means
Complete Stage genuinely cannot appear without `platform` set. It's required in fact, not just in
the draft's own claim.
- First-ever shift: no previous item exists, so pre-fill is empty and the driver must type it once.
  The plan states this outcome explicitly (Step 7 live check: "Platform is pre-filled after the
  first ever shift; empty on the very first") rather than silently assuming pre-fill always works.
- Multi-platform / platform-switching drivers: pre-fill can copy a stale value, but it's visible and
  editable before the capture is written, and editable again afterward via the `platform [Save]`
  control. This is called out and accepted as a residual risk (§8), not swept under the rug.
- Pre-fill correctly survives a shift moving from Start to End: `platform` is only on the Start
  checklist, so per the stated (and plausible, given the cited `move_stage` fix) rule that
  non-shared keys stay live in `item.data` across a stage move, a closed shift's `platform` is
  still readable when pre-filling the next shift. I did not re-derive this from the `move_stage`
  source myself, but it's internally consistent with the codebase facts the plan states elsewhere
  were verified by reading the code.

No new UX-friction bug found here.

**3. LocationIQ instead of Nominatim — fixes the ToS/blocking problem specifically; does not, and
does not claim to, eliminate third-party exposure.** I checked both halves independently:
- *Nominatim side*: the OSM Foundation's usage policy does treat periodic app requests as the kind
  of traffic that gets auto-blocked (community reporting puts the trigger around >1 req/s, with a
  403 page and an automatic unblock after a few hours). Round 1's objection was real, and moving off
  the public Nominatim instance is the correct fix for *that* objection.
- *LocationIQ side*: its own help-center article says it does not log the content of API calls
  except temporarily for debugging with customer consent, and its free tier does genuinely allow
  "limited commercial use" with attribution — so the ToS concern is resolved by switching vendors,
  and the plan's attribution link and `LOCATIONIQ_API_KEY` secret handling are correctly specified.
  But the plan is explicit, not evasive, that this *moves* rather than *removes* the privacy
  exposure: §5 states plainly that "LocationIQ... receives the rounded point in its request URL.
  Its server logs are a third-party retention point this app doesn't control." That is an honest
  and correct characterization — sending coordinates in our own function's POST body only keeps
  them out of *our* invocation logs; LocationIQ's reverse endpoint is GET-only with lat/lon as query
  parameters, so LocationIQ's own server necessarily sees the coordinates regardless of how our
  client talks to our edge function. The plan does not claim otherwise. This is the correct answer
  to the question "does this resolve the concern or just move it" — it moves it, says so, and gates
  the user's acceptance of that move (Step 0.2) before work starts.

None of the three fixes is cosmetic; all three hold up under independent checking. I did not find
grounds to re-open any of them as blocking.

## New findings

### Worth considering (not blocking)

1. **(critique) The Step 0.2 "decide whether to accept LocationIQ / keep `start_area`" gate has no
   wired-up fallback path if the answer is no.** §5 names two fallbacks — drop `reverse-geocode`
   and store a rounded coordinate string, or swap to Geoapify — but neither is specified at the
   level the rest of the plan is (no file/step changes listed for either branch, the way Steps 1–6
   spell out the LocationIQ path). If the user declines LocationIQ at Step 0.2, the plan as written
   doesn't say which concrete edits to Step 2 (stage checklists), Step 5b (function body), Step 6a
   (whether `geolocation.js` is even needed), and Step 6f (UI) follow. Given this is a decision gate
   placed *before* any other step, an unresolved "no" branch could stall implementation right at the
   start. Fix: either commit to LocationIQ as the only path for Phase 1 and drop the opt-out framing
   from Step 0.2, or write out the alternate path with the same step-by-step specificity as the
   primary path (even a few bullet points under each affected step would do it).

2. **(alternative) A fully offline reverse-geocode avoids the third-party-exposure question
   entirely, and may be a better fit than either LocationIQ or Geoapify for this app's actual
   usage pattern.** This is a single user driving in (presumably) one or two metro areas. A small
   bundled dataset of neighborhood/city boundaries for just those metros (e.g. a local point-in-
   polygon lookup against a few hundred KB of GeoJSON, no network call at all) would give the same
   "Wicker Park, Chicago"-style label, remove LocationIQ/Geoapify/Nominatim from the picture
   entirely, remove the API-key secret and the rate-limit/ToS surface, and remove the §9.4 and §9.5
   "taken on faith from pricing pages" assumptions altogether. The tradeoff is coarser, static
   boundaries and some up-front work to source/bundle the data for the driver's metro(s) — a real
   cost, which is presumably why the plan didn't choose it — but it's a concrete, nameable
   alternative that's strictly better on the privacy axis the plan spent the most words on, and it's
   worth a sentence in §5's alternatives list next to Geoapify, even if it's rejected for Phase 1.

3. **(critique, minor) Step 5d's logging check only exercises inbound request logging.** The smoke
   test opens the dev project's function *invocation* logs to confirm the body/coordinates aren't
   recorded there — correct for verifying assumption §9.5 — but says nothing about whatever logging
   Supabase's platform may do of the function's *outbound* fetch to LocationIQ. In practice this is
   very unlikely to be an issue (Deno edge functions' outbound `fetch` calls aren't typically
   captured by Supabase's own logging), so this is not a privacy hole, just a gap in the stated
   verification step relative to what it implicitly claims to confirm. A one-line addition noting
   that outbound-fetch logging wasn't checked (because it's not expected to exist) would make the
   verification claim in §5 fully honest rather than partially so.

4. **(nit) §9.1's hedge on the citation is now stale.** As confirmed above, the paragraph letter is
   right and the quoted language matches. Update §9.1 to say it's confirmed (with the Cornell LII
   quote), rather than leaving it listed as an unverified assumption to "confirm... before the
   citation goes into the migration header" — the migration header can now state the aggregation
   rule as settled, not tentative.

### Nothing found at "must address before implementation" severity

I looked hard at the SQL in Step 1 (signed-weight validation, the two new STABLE helper functions,
the CHECK re-add, the three changed CTEs in `report_series`) and at the C# logic in Steps 6c/6d/6f
(the new `IsClosed` predicate against the mechanic/Nutrition/Expense/Shift stage shapes, the
platform patch-building order, the area-lookup deadline). I traced through the edge cases each
claims to handle (malformed timestamps hitting the exception handler and returning null rather than
raising; `item_date_key` absent falling back to `created_at`; zero-weight still rejected while
negative weights are now allowed; the mechanic `closed` stage's vacuous-`All()` match keeping
today's behavior; the Expenses single-stage workflow never being treated as "closed") and didn't
find a case where the stated behavior and the actual logic diverge. The content-rollback SQL's
delete order respects the FK graph (`chat_messages`/`agent_events`/`item_events` before
`items`/`stages`/`workflows`), and the count guard is a reasonable blast-radius check. The
`parse: "timestamp"` keep-vs-cut writeup gives an accurate, checkable list of exactly what to
delete if someone wants to cut it later. None of this rises to a blocking defect.

## Verdict

All three of round 1's blocking issues are genuinely fixed, not just claimed to be fixed — I
independently verified the regulation citation against the actual CFR text, verified `platform`'s
required status against the migration SQL and the `DoneNextStage` gating logic rather than the
prose describing them, and independently assessed that the LocationIQ switch resolves the specific
ToS/blocking defect from round 1 while being honest (not evasive) about the privacy exposure it
does not resolve. The new findings above are all "worth considering" — the most actionable is
tightening the Step 0.2 decision gate so a "no" to LocationIQ has a concrete follow-on path, and
naming an offline/local reverse-geocode as an alternative worth a sentence in §5 — but none of them
is a correctness or feasibility defect that should hold up the plan.

**Nothing here is severe enough to block advancing to architect-review.**
