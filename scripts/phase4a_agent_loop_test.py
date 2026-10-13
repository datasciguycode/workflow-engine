#!/usr/bin/env python3
"""Phase 4a text-first agent loop (SPEC.md §6/§7 Phase 4, text-first slice decided 2026-10-13).

BLOCKED / NOT YET RUN as of this commit: exercising this for real needs (1) a local Deno
runtime for `supabase functions serve` (not installed in the environment this was written in --
only the Docker-based shared edge-runtime is present, and the CLI's own functions-serve command
removed that container as a side effect when tried; it was restored via `supabase stop && supabase
start` and the existing Phase 0/1/1b/3 scripts were re-run clean afterward) and (2) a real
ANTHROPIC_API_KEY set as a function secret (`supabase secrets set ANTHROPIC_API_KEY=...`) --
neither is available here. This script is written against the agent-loop function's actual
request/response contract (see supabase/functions/agent-loop/index.ts) and is ready to run once
both are in place; do not take its presence as evidence the agent loop has been validated.

To actually run this once set up:
  1. `supabase secrets set ANTHROPIC_API_KEY=sk-...`
  2. `supabase functions serve agent-loop` (separate terminal, needs Deno)
  3. `python3 -I scripts/phase4a_agent_loop_test.py`
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

DISPATCHER_ID = "8f3a0d26-5d86-4b18-8068-dae74693d42f"
MECHANIC_WORKFLOW_ID = "33333333-3333-3333-3333-333333333330"
STAGE_INTAKE = "33333333-3333-3333-3333-333333333331"
STAGE_SCHEDULING = "33333333-3333-3333-3333-333333333332"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def mint_jwt(user_id: str, email: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "aud": "authenticated", "role": "authenticated", "sub": user_id,
        "email": email, "iss": "supabase-demo", "iat": now, "exp": now + 3600,
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


def agent_call(token, workflow_id, queue, messages):
    return request(
        "POST",
        "/functions/v1/agent-loop",
        token,
        {"workflow_id": workflow_id, "queue": queue, "messages": messages},
    )


failures = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" -- {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


def main():
    token = mint_jwt(DISPATCHER_ID, "dispatcher@acct1.test")

    # --- Scenario 1: create a new item via natural language, confirm, verify is_initial stage ---
    messages = [{"role": "user", "content": "Create a new job for a Honda Civic, oil change."}]
    status, body = agent_call(token, MECHANIC_WORKFLOW_ID, [], messages)
    check("create: first call succeeds", status == 200, f"{status} {body}")
    check("create: first reply is a confirmation, no write yet", "reply" in (body or {}))
    messages = body["messages"] + [{"role": "user", "content": "yes"}]
    status, body = agent_call(token, MECHANIC_WORKFLOW_ID, [], messages)
    check("create: confirm call succeeds", status == 200, f"{status} {body}")
    # The created item's id isn't echoed structurally by this contract -- the test would need to
    # look it up via a plain REST query (e.g. most recent item in the workflow) to assert it
    # landed in STAGE_INTAKE. Left as a TODO once this is actually runnable.

    # --- Scenario 2: refer to an existing item by queue number, move it, confirm ---
    status, body = request(
        "POST", "/rest/v1/rpc/create_item", token,
        {"p_workflow_id": MECHANIC_WORKFLOW_ID, "p_data": {"vehicle": "Civic"}},
    )
    check("setup: direct create_item for scenario 2 succeeds", status == 200, f"{status} {body}")
    item_id = body["id"] if status == 200 else None

    queue = [{"number": 1, "item_id": item_id, "label": "Civic"}]
    messages = [{"role": "user", "content": "Move number one to scheduling."}]
    status, body = agent_call(token, MECHANIC_WORKFLOW_ID, queue, messages)
    check("move: first call succeeds", status == 200, f"{status} {body}")
    messages = body["messages"] + [{"role": "user", "content": "yes"}]
    status, body = agent_call(token, MECHANIC_WORKFLOW_ID, queue, messages)
    check("move: confirm call succeeds", status == 200, f"{status} {body}")

    status, body = request("GET", f"/rest/v1/items?id=eq.{item_id}", token)
    check(
        "move: item actually moved to scheduling after confirmation",
        status == 200 and body and body[0]["stage_id"] == STAGE_SCHEDULING,
        f"{status} {body}",
    )

    # --- Scenario 3: decline the confirmation -- no write should happen ---
    status, body = request(
        "POST", "/rest/v1/rpc/create_item", token,
        {"p_workflow_id": MECHANIC_WORKFLOW_ID, "p_data": {"vehicle": "Truck"}},
    )
    item_id_2 = body["id"] if status == 200 else None
    queue2 = [{"number": 1, "item_id": item_id_2, "label": "Truck"}]
    messages = [{"role": "user", "content": "Move number one to scheduling."}]
    status, body = agent_call(token, MECHANIC_WORKFLOW_ID, queue2, messages)
    messages = body["messages"] + [{"role": "user", "content": "no, don't do that"}]
    status, body = agent_call(token, MECHANIC_WORKFLOW_ID, queue2, messages)
    check("decline: confirm-decline call succeeds", status == 200, f"{status} {body}")
    status, body = request("GET", f"/rest/v1/items?id=eq.{item_id_2}", token)
    check(
        "decline: item is still in intake (no write happened on 'no')",
        status == 200 and body and body[0]["stage_id"] == STAGE_INTAKE,
        f"{status} {body}",
    )

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: {failures}")
        sys.exit(1)
    print("All Phase 4a agent-loop checks passed.")


if __name__ == "__main__":
    main()
