# Round-1 sanity check: rideshare mileage/expenses plan

Scope: is each design decision actually correct/the right call, independent of clarity review.
Verified against the plan text, the codebase facts it cites, and external research (IRS/Treas.
Reg. substantiation case law, Nominatim's usage policy).

---

## Must address before implementation

### 1. The plan's core substantiation claim is weaker than it's treated, and the regulatory cite is wrong

The whole shift-unit design rests on one claim (§2, §9.1): a shift-level odometer start/end
satisfies §274(d) adequate records because Treas. Reg. §1.274-5T(c)(6)(i)(**B**) lets an
"uninterrupted business use" be one record. The plan flags this as an unverified assumption but
then treats it as structurally load-bearing for the whole data model and defers the obvious
mitigation (platform trip-history export) entirely out of scope.

Checked against actual Tax Court practice:
- The "uninterrupted business use may be accounted for by a single record" language is cited by
  courts to **(c)(6)(i)(C)**, not (B). (B) is about establishing the business-use vs. total-use
  split for listed property generally. The citation in the plan is simply wrong and should be
  fixed (or at minimum the letter dropped and replaced with "(c)(6)(i), special aggregation
  rules" pending a real read of the current eCFR text).
- More importantly: courts applying this rule have **rejected** logs that are exactly what this
  plan produces — a daily/per-period beginning-and-ending-odometer entry with no corroborating
  detail. In *Brown*, a log with daily start/stop odometer columns was rejected because the
  taxpayer provided no corroborating e-mails/calendar/other documentation. In *Ressen*, by
  contrast, the taxpayer's weekly mileage entries were accepted, but the deciding factor was
  credible, detailed, corroborated testimony, not the log's granularity. The pattern across the
  cases is: a bare start/end number, with no business-purpose detail and no corroboration, is
  exactly the kind of log that gets thrown out on audit.
- Rideshare has an available, free, contemporaneous corroborating record that this plan excludes
  entirely: Uber/Lyft's own per-trip/weekly trip history and tax summary (which already reports
  "online miles" vs. "on-trip miles" and exact per-trip detail). The plan puts "importing or
  exporting platform trip history" in out-of-scope (§10) as if it's an unrelated nice-to-have,
  when per the case law it is the thing that turns this app's shift log from "the kind of log
  that gets rejected" into "the kind of log that gets accepted."

**Fix:** This doesn't require new engineering. Reframe the design doc's own claim (don't ship a
false sense of audit-proof substantiation), and add one cheap thing to Phase 1: a persistent
UI reminder (static copy, no new field/engine work) telling the driver to save/export the
platform's own weekly trip-history/tax-summary PDF or CSV as the corroborating record, and
treating this app's shift log explicitly as "deadhead/waiting miles the platform doesn't
report" rather than as a complete substitute for the platform's own trip data. That one-line
scope change costs nothing and fixes the single highest-stakes gap in the plan.

### 2. "Business purpose" (`platform`) is optional, contradicting the plan's own requirement table

§3's requirement table lists "Business purpose" as a per-use IRS requirement and says it's met by
the new `platform` field. But in Step 2's stage definition, `platform` is in
`optional_checklist` for the Start stage — only `start_odometer` and `start_time` are required
(`checklist.Except(optional_checklist)`). If a driver never fills `platform`, every shift that
workflow produces is missing the one field the plan itself says satisfies a mandatory
substantiation element, and nothing in the plan surfaces that gap to the user.

**Fix:** Either make `platform` required (drop it from `optional_checklist`), or default-fill it
(e.g. pre-populate "Uber" from the last shift's value, still editable) so the business-purpose
field is populated without adding driver friction. Don't leave a documented-as-required field
silently optional.

### 3. Reverse-geocoding through the public Nominatim endpoint may not be a compliant or reliable choice for a live app, and its own server-side logging undercuts the "rounded, in transit only" privacy claim

The plan flags (§9.3) that it couldn't fetch Nominatim's usage policy and gates verification
before Step 5 — good instinct, but the finding should change the design, not just get a
footnote. Having read the actual policy (`operations.osmfoundation.org/policies/nominatim`):
- It explicitly states that **periodic requests from an application are themselves treated as
  "bulk geocoding"** under the policy, which the policy discourages/restricts on the public
  instance — this is exactly the call pattern the plan is proposing (every shift capture, from
  every user, indefinitely). Low volume today doesn't change which policy clause this falls
  under, and the usual failure mode is a silent IP-level block with no advance warning, i.e. a
  feature that works in testing and then goes dark in production.
- Separately, the plan's retention analysis (§5, "Who sees the coordinate") says the rounded
  coordinate is seen by Nominatim "rounded, in transit only." That's not established — a
  standard web server access log on Nominatim's side (query string includes `lat`/`lon`) is
  **retention on infrastructure this app does not control**, for a duration this app cannot set
  or audit. The plan's "never store raw lat/lng" claim is true for *this app's own storage*, but
  the "in transit only" framing for the third party is an assumption, not a verified fact, and
  should be stated as such rather than as the thing the user is told to trust.
- A related, uncovered gap: Supabase Edge Functions' own platform-level invocation logging
  (`supabase functions logs`) may capture request metadata/query params independent of anything
  the function code does. The plan says the function "logs nothing," which is true of
  application-level logging, but doesn't address whether the hosting platform logs requests by
  default. Worth a 5-minute check before Step 5.

**Fix / alternative:** For this volume (a couple of geocodes per shift, single-digit users),
use a provider meant for live application traffic instead of the public Nominatim demo
instance — e.g. **Geoapify** (free tier, generous daily quota, meant for apps) or **LocationIQ**
(free tier, explicitly permits production app use). Either keeps the "tiny server proxy, no
client-side key" shape the plan already designed, just pointed at a different host, and avoids
betting a feature on a policy carve-out instead of a sanctioned one. If Nominatim is kept
anyway, say explicitly in §5 that OSM's own server-side logs are an uncontrolled third-party
retention point, not "transit only."

---

## Worth considering

### 4. One of the four generic engine extensions (`parse: "timestamp"`) has a weak cost/benefit ratio for Phase 1

Of the four extensions:
- **Signed weights** and **`item_date_key`** are clearly justified — the former is a one-line
  constraint relaxation, the latter fixes a real correctness bug (a Dec-31 expense logged Jan 2
  would land in the wrong tax year without it).
- **`hidden`** is cheap and reused for both new fields that need to exist as derived-field
  components without being shown.
- **`parse: "timestamp"` + `jsonb_epoch`**, by contrast, exists to support exactly one report
  card: "Hours online" (`end_time − start_time`). It adds a new STABLE plpgsql function with
  exception-handling per row, a new base-field validation branch, and a new CTE change in
  `report_series`, all of which must be re-verified not to regress Nutrition. That's a
  nontrivial, permanent addition to a shared generic engine, to buy one card in a
  not-yet-launched workflow.

**Alternative:** Ship Phase 1 without "Hours online" (cut the field and the `parse`/`jsonb_epoch`
machinery entirely), and bring it back in Phase 2 alongside the ratio-of-sums work that
"earnings per hour" already needs (the plan itself says the two belong together: "the driver
divides two cards" until ratio support exists — if that's an acceptable Phase 1 gap, the
`hours` card creating the gap can wait too). This shrinks Step 1 from four engine extensions to
three, with no loss of the features the user actually asked for first (miles, earnings, tolls,
parking all ship either way).

### 5. Odometer plausibility bounds catch gross misreads, not digit transpositions, which are the error mode actually called out

§4 lists 6↔8, 1↔7, 3↔8 confusion as classic misread errors, and the bounds checks are "End <
Start" and "> 1,000 mi jump." A single-digit misread in, say, the hundreds place (e.g. 48,213 →
48,813) changes the tax-relevant mileage by hundreds of miles but will clear both bounds checks
silently, with no plausibility signal at all. This is a real residual gap, though the plan's
existing mitigations (mandatory manual-type fallback, "Correct reading" affordance, audited
`item_events` trail) are reasonable and already go further than scan-vin/scan-plate did. Not
blocking, but worth an explicit note in §9 alongside the other accepted-risk assumptions, since
it's a different risk shape than what's already listed there (those are about the model not
being able to tell which number is odometer; this is about a wrong-but-plausible odometer
number).

### 6. Discarding the odometer photo may be the wrong call for *this* workflow, even though it's the right call for scan-vin/scan-plate

The "photo never stored" rule is sound for VIN/plate scans, which are just data-entry
conveniences with no evidentiary purpose of their own. Here, the photo *is* potentially useful
original evidence for a tax record — if the digits are ever questioned, "here's the dashboard
photo from that moment" is stronger than "here's a timestamped text note." The plan places
"storing odometer photos as evidence" in out-of-scope, citing the need for a Storage bucket and
retention policy as if that's necessarily a big lift. Worth reconsidering as a cheap opt-in
(e.g., one private Storage bucket, no public access, same retention as everything else) rather
than a blanket "no," specifically because this workflow's purpose is evidentiary in a way the
precedent features weren't. Not a blocker — the plan's fallback (manual correction + audit
trail) is a reasonable substitute — but it's a case where copying the precedent without
re-examining it may not serve the actual goal.

### 7. Area labels still disclose approximate home location; the privacy win over raw coordinates is more modest than implied

§5 rejects storing a rounded coordinate partly because "it still pinpoints a neighbourhood," and
chooses a human-readable neighborhood/suburb label instead. But a repeated `"{prefix}_area"` of
"Wicker Park, Chicago" for most shift-starts discloses the same thing a rounded coordinate would
have — approximate home location — just in friendlier text, and it's *more* exposed to a human
reader skimming the item list than a raw coordinate would be (a lat/lng needs a lookup; a named
neighborhood doesn't). This isn't a reason to abandon the approach — optional capture, best
effort, denial-safe are all good — but the plan's framing implies the label is the more
privacy-protective choice, when in terms of "what does this tell a reader about where I live" it
isn't clearly better than the rejected alternative. Worth being honest about in the plan's own
write-up rather than presenting the chosen design as strictly safer.

### 8. Regulatory citation should be fixed regardless of the above

Independent of finding 1's substance, `(c)(6)(i)(B)` vs. `(c)(6)(i)(C)` is a factual error the
plan can simply correct before this becomes the permanent justification text in a migration
header comment (Step 2 says the header will "summarise §2").

### 9. Minor: expense category boundary for "supplies" is asserted, not fully checked

§3 places phone mounts/dashcams/passenger amenities in "deductible alongside mileage," distinct
from the standard-mileage-rate-only categories. Some of these (a permanently installed phone
mount, a dashcam wired into the vehicle) could be read as vehicle accessories/improvements
subject to depreciation rules rather than freely deductible as supplies, depending on cost and
permanence. The plan already disclaims "not tax advice," so this doesn't need resolving here,
but the category write-up could note the ambiguity rather than asserting a clean line.

### 10. Minor: display-name de-duplication (Step 6d) only considers currently loaded items

Appending `HH:mm` when "another loaded item has the same local date" will miss collisions across
pages if the item list is ever paginated or filtered, re-introducing the "Logged 2026-11-19" /
"Logged 2026-11-19" ambiguity the step exists to fix. Low severity at current list sizes
(personal use, single user), but worth a one-line note that the fix is scoped to the currently
loaded window, not all items ever.

---

## Things checked and found sound (no finding)

- **Shift vs. ride as the unit of capture:** the engineering case (odometer quantization,
  double-counting on stacked rides, two-photos-per-ride-with-a-passenger being impractical) is
  solid on its own terms, independent of the substantiation question raised above. The decision
  to keep the capture UI identical and treat the change as "cheap to reverse" is realistic given
  what's shown.
- **Two workflows instead of one:** the lifecycle mismatch (expenses aren't shift-scoped) and the
  one-`report_config`-per-workflow constraint are both real, correctly identified constraints;
  splitting is the right call.
- **Tolls/parking staying on the shift, not in Expenses:** correctly reasoned to avoid double
  logging, and matches the tax treatment (deductible on top of the standard rate either way).
- **`report_fields_valid`/`report_series` SQL changes (Step 1a/1e):** traced through carefully —
  the zero-weight-still-rejected, parse-only-on-base-fields, hidden-is-boolean-only validation
  branches, and the `::timestamp`-before-`date_trunc` session-TimeZone-independence note, are all
  correct as written and the regression-safety plan (verbatim CTE copy, before/after diff,
  updated dev-check assertions) is appropriately cautious.
- **`IsClosed` predicate (Step 6c):** traced through all four affected stage shapes (Mechanic
  `closed`, Nutrition `dinner`, Expenses `logged`, Shift `end`) and it produces the stated
  behavior in each case; no edge case found where it misclassifies.
- **`jsonb_epoch`/`item_local_date` regex and exception handling:** correctly anticipates that a
  regex alone can't reject something like month 13, and wraps the cast in a handler that returns
  null instead of aborting the whole report — this is the right level of defensiveness for a
  function whose output feeds an aggregate over many rows.
- **Deferral of downtime/earnings-per-hour/per-area breakdown to Phase 2:** each is correctly
  shown to need a materially different, bigger engine feature (cross-item window, ratio, group-by)
  that doesn't exist yet, and downtime specifically is correctly identified as meaningless once
  the unit is a shift. No case found for pulling any of these into Phase 1.

---

## Verdict

Nothing here is a "this design is unworkable" blocker — the engineering (schema, SQL, edge
functions, UI) is carefully done and the regression-safety discipline is good. But **findings 1
and 2 together are severe enough that the plan should not advance to implementation as written**:
the plan is building a tax-substantiation feature while (a) misquoting the regulation it leans
on, (b) excluding the one corroborating record (platform trip-history export) that case law
suggests is what actually makes a bare odometer log defensible, and (c) leaving the
"business purpose" field optional even though the plan's own table marks it required. These are
cheap to fix (a documentation/citation correction, one scope line moved from out-of-scope to
Phase 1, one checklist-field change) and fixing them before Step 2 ships the content migration
costs far less than fixing them after real driver data exists in the new fields. Finding 3
(Nominatim) should also be resolved — by reading the actual policy and most likely switching
providers — before Step 5, which the plan already gates but should treat as "probably switch
providers," not "probably fine."

Everything in "Worth considering" can reasonably be deferred or accepted as-is; none of it
should hold up Step 0–4.
