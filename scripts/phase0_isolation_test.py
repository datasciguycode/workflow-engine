#!/usr/bin/env python3
"""Phase 0 exit criterion (SPEC.md §1A "Isolation test"): two seeded users, each owning their
own account, must not be able to see or write each other's data, and actor must be unspoofable.

Run against the local Supabase stack only (`supabase start`), using the fixtures in seed.sql.
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
# Local dev default from `supabase start` (supabase/config.toml), not a real secret -- used here
# to mint test JWTs directly rather than going through GoTrue's password-login flow, which is
# gated by a signup/login provider toggle that's out of scope to touch for a local test run.
JWT_SECRET = "super-secret-jwt-token-with-at-least-32-characters-long"


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


ACCT1 = {
    "account_id": "11111111-1111-1111-1111-111111111111",
    "workflow_id": "11111111-1111-1111-1111-111111111112",
    "stage1_id": "11111111-1111-1111-1111-111111111113",
    "stage2_id": "11111111-1111-1111-1111-111111111114",
    "item_id": "11111111-1111-1111-1111-111111111115",
    "user_id": "8f3a0d26-5d86-4b18-8068-dae74693d42f",
}
ACCT2 = {
    "account_id": "22222222-2222-2222-2222-222222222221",
    "workflow_id": "22222222-2222-2222-2222-222222222222",
    "stage1_id": "22222222-2222-2222-2222-222222222223",
    "stage2_id": "22222222-2222-2222-2222-222222222224",
    "item_id": "22222222-2222-2222-2222-222222222225",
    "user_id": "62e02840-6ac9-4c69-965d-c8f647a5bb18",
}

failures = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" -- {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


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
    token_a = mint_jwt(ACCT1["user_id"], "usera@acct1.test")
    token_b = mint_jwt(ACCT2["user_id"], "userb@acct2.test")
    print("Minted test JWTs for both A and B.\n")

    # --- Sanity: A can see A's own data ---
    status, body = request("GET", f"/rest/v1/workflows?id=eq.{ACCT1['workflow_id']}", token_a)
    check("A can read A's own workflow", status == 200 and len(body) == 1)

    # --- (1) A gets zero rows selecting B's workflows/stages/items/events ---
    status, body = request("GET", f"/rest/v1/workflows?id=eq.{ACCT2['workflow_id']}", token_a)
    check("A sees zero rows for B's workflow", status == 200 and body == [], f"{status} {body}")

    status, body = request("GET", f"/rest/v1/stages?id=eq.{ACCT2['stage1_id']}", token_a)
    check("A sees zero rows for B's stage", status == 200 and body == [], f"{status} {body}")

    status, body = request("GET", f"/rest/v1/items?id=eq.{ACCT2['item_id']}", token_a)
    check("A sees zero rows for B's item", status == 200 and body == [], f"{status} {body}")

    status, body = request("GET", f"/rest/v1/item_events?item_id=eq.{ACCT2['item_id']}", token_a)
    check("A sees zero rows for B's item_events", status == 200 and body == [], f"{status} {body}")

    # --- (2a) A's item insert into B's workflow fails ---
    # create_item's signature changed in Phase 1 (SPEC.md §2): it now derives the target stage
    # from the workflow's own is_initial stage rather than taking one from the caller, so this
    # now fails at the stages lookup (stages_select RLS) before ever reaching the items INSERT --
    # it no longer exercises items_insert's own cross-account WITH CHECK. The direct-insert check
    # right below restores that coverage independently of create_item's internal lookup.
    status, body = request(
        "POST",
        "/rest/v1/rpc/create_item",
        token_a,
        {"p_workflow_id": ACCT2["workflow_id"], "p_data": {}},
    )
    check("A's create_item into B's workflow fails", status >= 400, f"{status} {body}")

    status, body = request(
        "POST",
        "/rest/v1/items",
        token_a,
        {"workflow_id": ACCT2["workflow_id"], "stage_id": ACCT2["stage1_id"], "data": {}},
    )
    check("A's direct items insert into B's workflow fails", status >= 400, f"{status} {body}")

    # --- (2b) A's move_stage on B's item fails ---
    status, body = request(
        "POST",
        "/rest/v1/rpc/move_stage",
        token_a,
        {"p_item_id": ACCT2["item_id"], "p_to_stage_id": ACCT1["stage2_id"]},
    )
    check("A's move_stage on B's item fails", status >= 400, f"{status} {body}")

    # --- (3) item_events insert with actor spoofed to B's uuid fails ---
    status, body = request(
        "POST",
        "/rest/v1/item_events",
        token_a,
        {
            "item_id": ACCT1["item_id"],
            "event_type": "item.note_added",
            "actor": ACCT2["user_id"],
            "data": "spoof attempt",
        },
    )
    check("A's item_events insert with spoofed actor fails", status >= 400, f"{status} {body}")

    # --- (4) private.is_member isn't reachable as an RPC for anyone ---
    status, body = request("POST", "/rest/v1/rpc/is_member", token_a, {"acct": ACCT1["account_id"]})
    check("private.is_member is not exposed as an RPC", status == 404, f"{status} {body}")

    # --- Sanity: A's legitimate RPCs on A's own data still work ---
    status, body = request(
        "POST",
        "/rest/v1/rpc/move_stage",
        token_a,
        {"p_item_id": ACCT1["item_id"], "p_to_stage_id": ACCT1["stage2_id"]},
    )
    check("A's move_stage on A's own item succeeds", status == 200, f"{status} {body}")

    status, body = request(
        "POST",
        "/rest/v1/item_events",
        token_a,
        {"item_id": ACCT1["item_id"], "event_type": "item.note_added", "data": "legit note"},
    )
    check(
        "A's item_events insert with real actor (own identity) succeeds",
        status in (200, 201),
        f"{status} {body}",
    )

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {failures}")
        sys.exit(1)
    print("All isolation checks passed. Phase 0 exit criterion met.")


if __name__ == "__main__":
    main()
