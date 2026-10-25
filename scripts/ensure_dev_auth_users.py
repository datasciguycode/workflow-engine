#!/usr/bin/env python3
"""Ensures the fixture auth.users rows referenced by seed.sql actually exist.

Real bug found 2026-10-16: seed.sql's account_members/items rows reference fixed user ids
(dispatcher, mechanic, acct2 owner), but those ids were only ever created once, by hand, via
the Auth Admin API -- never by a committed script. `supabase db reset` wipes auth.users every
time, so every reset silently breaks any write that triggers an item_events insert (its `actor`
column defaults to auth.uid(), with an FK to auth.users) -- reads and even an agent "ping" with
no tool call look fine, which is why this went unnoticed for a full day of resets.

Run this once after every `supabase db reset` (or `supabase start` on a fresh volume):
    python3 scripts/ensure_dev_auth_users.py

Idempotent: a user id that already exists is left alone (Admin API returns 422/"already
registered" for a duplicate, which this script treats as success, not failure).
"""
import json
import sys
import urllib.error
import urllib.request

API_URL = "http://127.0.0.1:54321"
# Local dev default from `supabase status` -- not a real secret, same local Docker stack as the
# other fixed keys already committed in scripts/*.py and supabase/seed.sql.
SERVICE_ROLE_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vf"
    "cm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
)

# Must match the ids seed.sql assigns to account_members -- see supabase/seed.sql.
FIXTURE_USERS = [
    ("8f3a0d26-5d86-4b18-8068-dae74693d42f", "dispatcher@acct1.test"),  # Dana (dispatcher)
    ("e5445381-e390-4943-bc80-91ba0c60a048", "mechanic@acct1.test"),  # Max (mechanic)
    ("62e02840-6ac9-4c69-965d-c8f647a5bb18", "owner@acct2.test"),  # acct_2 isolation-test owner
]


def ensure_user(user_id: str, email: str) -> None:
    body = json.dumps({
        "id": user_id,
        "email": email,
        "password": f"local-dev-only-{user_id}",
        "email_confirm": True,
    }).encode()
    req = urllib.request.Request(
        f"{API_URL}/auth/v1/admin/users",
        data=body,
        method="POST",
        headers={
            "apikey": SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
            "Content-Type": "application/json",
        },
    )
    try:
        urllib.request.urlopen(req)
        print(f"created {email} ({user_id})")
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        if e.code == 422 and "already" in detail.lower():
            print(f"already exists: {email} ({user_id})")
        else:
            print(f"FAILED {email} ({user_id}): {e.code} {detail}", file=sys.stderr)
            raise


if __name__ == "__main__":
    for user_id, email in FIXTURE_USERS:
        ensure_user(user_id, email)
