#!/usr/bin/env python3
"""Phase 3 (SPEC.md §3/§5/§7): build the SDLC workflow, discovering enforce_stage_order.

Traces SPEC.md §5's exact scenario against the seeded "Feature Pipeline" workflow:
  - create_item lands in 'spec' (is_initial).
  - a direct forward skip (spec -> test) is REJECTed: enforce_stage_order is true, both
    endpoints have a sequence_order, 4 > 1 (forward), and 4 != 1 + 1 (not lockstep).
  - the normal lockstep path (spec->prototype->refactor->test) is ALLOWed.
  - a backward move out of test back to refactor (to fix failures) is ALLOWed unconditionally --
    enforce_stage_order never blocks backward/sideways moves, only forward skips.
  - re-advancing refactor->test is ALLOWed (lockstep again), then test->deploy (4->5) is ALLOWed,
    landing the item in deploy (is_terminal).
  - a null-sequence_order exemption: moving into/out of a stage with no sequence_order is always
    ALLOWed even when enforce_stage_order is true (checked against a throwaway unordered stage
    added to this workflow for the purpose of this test only).
  - confirms the mechanic workflow (enforce_stage_order = false) still allows its own forward
    skip unconditionally -- i.e. this migration didn't regress Phase 1/1b's behavior.

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
SDLC_WORKFLOW_ID = "44444444-4444-4444-4444-444444444440"
STAGE_SPEC = "44444444-4444-4444-4444-444444444441"
STAGE_PROTOTYPE = "44444444-4444-4444-4444-444444444442"
STAGE_REFACTOR = "44444444-4444-4444-4444-444444444443"
STAGE_TEST = "44444444-4444-4444-4444-444444444444"
STAGE_DEPLOY = "44444444-4444-4444-4444-444444444445"

MECHANIC_WORKFLOW_ID = "33333333-3333-3333-3333-333333333330"

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


def move(token, item_id, to_stage):
    return request("POST", "/rest/v1/rpc/move_stage", token, {"p_item_id": item_id, "p_to_stage_id": to_stage})


def main():
    token = mint_jwt(USER_A_ID, "usera@acct1.test")

    # --- create item, lands in spec ---
    status, body = request("POST", "/rest/v1/rpc/create_item", token, {"p_workflow_id": SDLC_WORKFLOW_ID, "p_data": {"title": "Add CSV export"}})
    check("create_item succeeds", status == 200, f"{status} {body}")
    item_id = body["id"]
    check("new item lands in 'spec' (is_initial)", body["stage_id"] == STAGE_SPEC)

    # --- forward skip spec -> test is rejected ---
    status, body = move(token, item_id, STAGE_TEST)
    check("direct forward skip spec -> test is REJECTed", status >= 400, f"{status} {body}")

    status, body = request("GET", f"/rest/v1/items?id=eq.{item_id}", token)
    check("item is still in 'spec' after the rejected skip", status == 200 and body[0]["stage_id"] == STAGE_SPEC, f"{body}")

    # --- lockstep forward: spec -> prototype -> refactor -> test ---
    for stage in (STAGE_PROTOTYPE, STAGE_REFACTOR, STAGE_TEST):
        status, body = move(token, item_id, stage)
        check(f"lockstep move to {stage} succeeds", status == 200 and body.get("stage_id") == stage, f"{status} {body}")

    status, body = request("POST", "/rest/v1/rpc/add_note", token, {"p_item_id": item_id, "p_note": "demoed to PM, approved to continue"})
    check("add_note succeeds", status == 200, f"{status} {body}")

    # --- backward move test -> refactor, unconditionally allowed ---
    status, body = move(token, item_id, STAGE_REFACTOR)
    check("backward move test -> refactor is ALLOWed unconditionally", status == 200 and body.get("stage_id") == STAGE_REFACTOR, f"{status} {body}")

    # --- re-advance refactor -> test (lockstep again), then test -> deploy ---
    status, body = move(token, item_id, STAGE_TEST)
    check("re-advance refactor -> test succeeds", status == 200 and body.get("stage_id") == STAGE_TEST, f"{status} {body}")

    status, body = move(token, item_id, STAGE_DEPLOY)
    check("final move test -> deploy succeeds", status == 200 and body.get("stage_id") == STAGE_DEPLOY, f"{status} {body}")
    check("item lands in 'deploy' (is_terminal)", body.get("stage_id") == STAGE_DEPLOY)

    # --- null-sequence_order exemption: a second, fresh item moved into an unordered stage ---
    status, body = request("POST", "/rest/v1/rpc/create_item", token, {"p_workflow_id": SDLC_WORKFLOW_ID, "p_data": {}})
    item2_id = body["id"]
    # Idempotent: reuse the throwaway stage across repeated runs instead of failing on the
    # (workflow_id, title) unique constraint.
    status, body = request(
        "GET", f"/rest/v1/stages?workflow_id=eq.{SDLC_WORKFLOW_ID}&title=eq.on_hold%20(unordered%2C%20test-only)",
        token,
    )
    if status == 200 and body:
        unordered_stage_id = body[0]["id"]
    else:
        status, body = request(
            "POST", "/rest/v1/stages",
            token,
            {"workflow_id": SDLC_WORKFLOW_ID, "title": "on_hold (unordered, test-only)", "sequence_order": None},
            prefer="return=representation",
        )
        check("unordered throwaway stage insert succeeds", status in (200, 201), f"{status} {body}")
        unordered_stage_id = body[0]["id"] if isinstance(body, list) else body["id"]

    status, body = move(token, item2_id, unordered_stage_id)
    check("move into a null-sequence_order stage is ALLOWed even with enforce_stage_order=true", status == 200, f"{status} {body}")

    status, body = move(token, item2_id, STAGE_TEST)
    check(
        "move from a null-sequence_order stage forward is also ALLOWed (exemption applies either side)",
        status == 200,
        f"{status} {body}",
    )

    # --- regression check: mechanic workflow's forward skip is still unconditionally allowed ---
    status, body = request("POST", "/rest/v1/rpc/create_item", token, {"p_workflow_id": MECHANIC_WORKFLOW_ID, "p_data": {}})
    mech_item_id = body["id"]
    status, body = move(
        token, mech_item_id,
        "33333333-3333-3333-3333-333333333338",  # payment_receipt_submitted, a big forward skip from intake
    )
    check(
        "mechanic workflow (enforce_stage_order=false) still allows an arbitrary forward skip -- no regression",
        status == 200,
        f"{status} {body}",
    )

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {failures}")
        sys.exit(1)
    print("All Phase 3 enforce_stage_order checks passed.")


if __name__ == "__main__":
    main()
