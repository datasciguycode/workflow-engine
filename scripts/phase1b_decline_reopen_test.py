#!/usr/bin/env python3
"""Phase 1b (SPEC.md §4/§7): port the decline and reopen branch.

Traces the exact decline/reopen path from SPEC.md §4 against the seeded mechanic workflow:
  - a job in `estimated` gets a decline_reason, then moves estimated -> closed (terminal).
  - reopening deletes decline_reason (top-level null in the merge-patch), appends to
    reopen_history (array replaced wholesale, not merged), and moves closed -> estimated --
    a backward move out of a terminal stage into a non-terminal one, which must be allowed
    unconditionally (is_terminal is a hint, not a block).
  - a second decline/reopen cycle confirms reopen_history accumulates both entries instead of
    clobbering the first (the array-replaced-wholesale caveat SPEC.md calls out).
  - two distinct signed-in members of acct_1 (dispatcher, mechanic) produce two distinct `actor`
    values in item_events, per the exit check in SPEC.md §7's Phase 1b description.

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

MECHANIC_WORKFLOW_ID = "33333333-3333-3333-3333-333333333330"
STAGE_ESTIMATED = "33333333-3333-3333-3333-333333333334"
STAGE_CLOSED = "33333333-3333-3333-3333-333333333339"

# Two distinct acct_1 members -- re-using the Phase 0 isolation-test user as "dispatcher" and
# minting a fresh id for "mechanic" (a second member of the same account, not another account).
DISPATCHER_ID = "8f3a0d26-5d86-4b18-8068-dae74693d42f"
MECHANIC_ID = "e5445381-e390-4943-bc80-91ba0c60a048"

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


def request(method, path, token=None, body=None):
    url = f"{API_URL}{path}"
    headers = {"apikey": ANON_KEY, "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
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
    dispatcher = mint_jwt(DISPATCHER_ID, "dispatcher@acct1.test")
    mechanic = mint_jwt(MECHANIC_ID, "mechanic@acct1.test")

    # --- set up: a fresh item, walked straight to estimated (mechanic records the diagnosis) ---
    status, body = request(
        "POST", "/rest/v1/rpc/create_item", dispatcher, {"p_workflow_id": MECHANIC_WORKFLOW_ID, "p_data": {}}
    )
    check("create_item succeeds", status == 200, f"{status} {body}")
    item_id = body["id"]

    for to_stage in (
        "33333333-3333-3333-3333-333333333332",  # scheduling
        "33333333-3333-3333-3333-333333333333",  # diagnosed
        STAGE_ESTIMATED,
    ):
        status, body = request(
            "POST", "/rest/v1/rpc/move_stage", mechanic, {"p_item_id": item_id, "p_to_stage_id": to_stage}
        )
        check(f"setup move to {to_stage} succeeds", status == 200, f"{status} {body}")

    status, body = request(
        "POST",
        "/rest/v1/rpc/update_data",
        mechanic,
        {"p_item_id": item_id, "p_patch": {"estimated_hours": 2, "hourly_rate": 75, "labor_cost": 150, "parts_cost": 60}},
    )
    check("estimate recorded", status == 200, f"{status} {body}")

    # --- decline: record decline_reason, move estimated -> closed ---
    status, body = request(
        "POST", "/rest/v1/rpc/update_data", mechanic, {"p_item_id": item_id, "p_patch": {"decline_reason": "too expensive"}}
    )
    check("decline_reason recorded", status == 200 and body["data"].get("decline_reason") == "too expensive", f"{status} {body}")

    status, body = request(
        "POST", "/rest/v1/rpc/move_stage", mechanic, {"p_item_id": item_id, "p_to_stage_id": STAGE_CLOSED}
    )
    check("move estimated -> closed succeeds", status == 200 and body.get("stage_id") == STAGE_CLOSED, f"{status} {body}")

    # --- reopen #1: delete decline_reason, add first reopen_history entry, move closed -> estimated ---
    status, body = request(
        "POST",
        "/rest/v1/rpc/update_data",
        dispatcher,
        {
            "p_item_id": item_id,
            "p_patch": {
                "decline_reason": None,
                "reopen_history": [{"reopened_at": "2026-10-13T00:00:00Z", "previous_closed_reason": "declined", "previous_decline_reason": "too expensive"}],
            },
        },
    )
    check("reopen #1 update_data succeeds", status == 200, f"{status} {body}")
    check("decline_reason key is deleted, not nulled", status == 200 and "decline_reason" not in body["data"], f"{body.get('data')}")
    check("reopen_history has 1 entry after first reopen", status == 200 and len(body["data"].get("reopen_history", [])) == 1)
    check(
        "original estimate fields untouched by the reopen patch",
        status == 200 and body["data"].get("estimated_hours") == 2 and body["data"].get("labor_cost") == 150,
    )

    status, body = request(
        "POST", "/rest/v1/rpc/move_stage", dispatcher, {"p_item_id": item_id, "p_to_stage_id": STAGE_ESTIMATED}
    )
    check(
        "backward move closed -> estimated (out of a terminal stage) succeeds unconditionally",
        status == 200 and body.get("stage_id") == STAGE_ESTIMATED,
        f"{status} {body}",
    )

    # --- decline + reopen #2: confirm reopen_history accumulates, doesn't clobber entry #1 ---
    status, body = request(
        "POST", "/rest/v1/rpc/update_data", mechanic, {"p_item_id": item_id, "p_patch": {"decline_reason": "still too expensive"}}
    )
    check("second decline_reason recorded", status == 200, f"{status} {body}")

    status, body = request(
        "POST", "/rest/v1/rpc/move_stage", mechanic, {"p_item_id": item_id, "p_to_stage_id": STAGE_CLOSED}
    )
    check("second move estimated -> closed succeeds", status == 200, f"{status} {body}")

    status, body = request("GET", f"/rest/v1/items?id=eq.{item_id}", dispatcher)
    existing_history = body[0]["data"].get("reopen_history", []) if status == 200 else []

    status, body = request(
        "POST",
        "/rest/v1/rpc/update_data",
        dispatcher,
        {
            "p_item_id": item_id,
            "p_patch": {
                "decline_reason": None,
                "reopen_history": existing_history + [{"reopened_at": "2026-10-13T01:00:00Z", "previous_closed_reason": "declined", "previous_decline_reason": "still too expensive"}],
            },
        },
    )
    check(
        "reopen #2 accumulates both entries (read-append-send), doesn't clobber entry #1",
        status == 200 and len(body["data"].get("reopen_history", [])) == 2,
        f"{body.get('data', {}).get('reopen_history')}",
    )

    # --- exit check: dispatcher's reopen and mechanic's diagnosis carry two distinct actors ---
    status, body = request("GET", f"/rest/v1/item_events?item_id=eq.{item_id}&order=seq.asc", dispatcher)
    check("item_events fetch succeeds", status == 200, f"{status} {body}")
    events = body or []
    actors = {e["actor"] for e in events}
    check(
        "events carry (at least) two distinct actors -- dispatcher and mechanic are told apart",
        len(actors) >= 2 and DISPATCHER_ID in actors and MECHANIC_ID in actors,
        f"{actors}",
    )

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {failures}")
        sys.exit(1)
    print("All Phase 1b decline/reopen checks passed.")


if __name__ == "__main__":
    main()
