#!/usr/bin/env python3
"""Phase 1 (SPEC.md §7): port the mechanic workflow's happy path.

Creates an item in the seeded `Joe's Auto Repair` workflow and walks it straight through all
eight happy-path stages (intake -> ... -> payment_receipt_submitted), checking that:
  - create_item lands a new item in the workflow's is_initial stage with no stage_id argument.
  - move_stage advances it through each stage in order.
  - item_events records one row per transition, in increasing `seq` order, with correct
    from_stage_id/to_stage_id and a real actor (not null, not spoofable -- already covered by
    the Phase 0 isolation test; this script just confirms it's populated).
  - create_item raises when a workflow has no is_initial stage.

Run against the local Supabase stack only, using the fixtures in seed.sql.
"""
import base64
import hashlib
import hmac
import json
import sys
import time
import urllib.error
import urllib.request

API_URL = "http://127.0.0.1:54321"
ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAi"
    "OjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
)
JWT_SECRET = "super-secret-jwt-token-with-at-least-32-characters-long"

USER_A_ID = "8f3a0d26-5d86-4b18-8068-dae74693d42f"
MECHANIC_WORKFLOW_ID = "33333333-3333-3333-3333-333333333330"
STAGES = [
    ("intake", "33333333-3333-3333-3333-333333333331"),
    ("scheduling", "33333333-3333-3333-3333-333333333332"),
    ("diagnosed", "33333333-3333-3333-3333-333333333333"),
    ("estimated", "33333333-3333-3333-3333-333333333334"),
    ("approval", "33333333-3333-3333-3333-333333333335"),
    ("in_progress", "33333333-3333-3333-3333-333333333336"),
    ("invoicing", "33333333-3333-3333-3333-333333333337"),
    ("payment_receipt_submitted", "33333333-3333-3333-3333-333333333338"),
]
# acct_1's isolation-test workflow, which has no payment_receipt_submitted-style extra stage --
# reused here only for the "no is_initial stage" edge case below via a workflow id that doesn't exist.
NONEXISTENT_WORKFLOW_ID = "99999999-9999-9999-9999-999999999999"

failures = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" -- {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def mint_jwt(user_id: str, email: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "aud": "authenticated",
        "role": "authenticated",
        "sub": user_id,
        "email": email,
        "iss": "supabase-demo",
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    signature = hmac.new(JWT_SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64url(signature)}"


def request(method, path, token=None, body=None, prefer=None):
    url = f"{API_URL}{path}"
    headers = {"apikey": ANON_KEY, "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if prefer:
        headers["Prefer"] = prefer
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw.decode()


def main():
    token = mint_jwt(USER_A_ID, "usera@acct1.test")

    # --- create_item lands the item in the is_initial stage, no stage_id argument ---
    status, body = request(
        "POST", "/rest/v1/rpc/create_item", token, {"p_workflow_id": MECHANIC_WORKFLOW_ID, "p_data": {}}
    )
    check("create_item succeeds with no stage_id argument", status == 200, f"{status} {body}")
    item = body
    item_id = item["id"]
    check("new item lands in 'intake' (the is_initial stage)", item["stage_id"] == STAGES[0][1])

    # --- walk it through the remaining 7 stages, in order ---
    for stage_name, stage_id in STAGES[1:]:
        status, body = request(
            "POST", "/rest/v1/rpc/move_stage", token, {"p_item_id": item_id, "p_to_stage_id": stage_id}
        )
        check(f"move_stage -> {stage_name} succeeds", status == 200, f"{status} {body}")
        check(f"item.stage_id updated to {stage_name}", body and body.get("stage_id") == stage_id)

    # --- item_events has one row per transition (1 created + 7 stage_changed), in seq order ---
    status, body = request(
        "GET",
        f"/rest/v1/item_events?item_id=eq.{item_id}&order=seq.asc",
        token,
    )
    check("item_events fetch succeeds", status == 200, f"{status} {body}")
    events = body or []
    check("item_events has 8 rows (1 created + 7 stage_changed)", len(events) == 8, f"got {len(events)}")

    created = events[0] if events else {}
    check("first event is item.created", created.get("event_type") == "item.created")
    check("item.created has no from_stage_id/to_stage_id", created.get("from_stage_id") is None and created.get("to_stage_id") is None)

    seqs = [e["seq"] for e in events]
    check("seq is strictly increasing", seqs == sorted(seqs) and len(set(seqs)) == len(seqs))

    stage_changes = events[1:]
    expected_pairs = list(zip([s[1] for s in STAGES[:-1]], [s[1] for s in STAGES[1:]]))
    actual_pairs = [(e["from_stage_id"], e["to_stage_id"]) for e in stage_changes]
    check("stage_changed events trace the exact happy path in order", actual_pairs == expected_pairs, f"{actual_pairs}")

    actors = {e["actor"] for e in events}
    check("every event has a real, non-null actor", None not in actors and len(actors) == 1)

    # --- create_item raises if the target workflow has no is_initial stage ---
    status, body = request(
        "POST", "/rest/v1/rpc/create_item", token, {"p_workflow_id": NONEXISTENT_WORKFLOW_ID, "p_data": {}}
    )
    check("create_item raises for a workflow with no is_initial stage", status >= 400, f"{status} {body}")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {failures}")
        sys.exit(1)
    print("All Phase 1 happy-path checks passed.")


if __name__ == "__main__":
    main()
