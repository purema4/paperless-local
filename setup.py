#!/usr/bin/env python3
"""Idempotent Paperless setup for receipts (AI processing is done by paperless-ai).

Creates (or updates) through the REST APIs:
  - tag: receipt
  - custom fields: Total, GST, QST, Paid by, Card last 4, Category, Event
  - workflow: every consumed document gets the receipt tag
  - mail account + 2 mail rules (only if MAIL_IMAP_SERVER is set in .env)

Usage:  python3 setup.py            (reads ./.env)
Only the standard library is used.
"""

import imaplib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAPERLESS = "http://localhost:8000"


def load_env():
    env = {}
    for line in (HERE / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        env[k.strip()] = v
    return env


ENV = load_env()
TOKEN = ENV.get("PAPERLESS_API_TOKEN", "")


def call(method, url, body=None, token=True):
    headers = {"Accept": "application/json; version=9", "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Token {TOKEN}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> {e.code}: {e.read().decode(errors='replace')[:800]}")


def api(method, path, body=None):
    return call(method, f"{PAPERLESS}/api/{path}", body)


def all_items(path):
    out, url = [], f"{PAPERLESS}/api/{path}?page_size=100"
    while url:
        page = call("GET", url)
        out += page["results"]
        url = page.get("next")
    return out


def upsert(path, name, body, compare_keys=None):
    """Create the object, or PATCH it if one with that name exists."""
    existing = {o["name"]: o for o in all_items(path)}
    body = {"name": name, **body}
    if name in existing:
        obj = existing[name]
        keys = compare_keys or body.keys()
        if any(obj.get(k) != body[k] for k in keys if k in obj):
            obj = api("PATCH", f"{path}{obj['id']}/", body)
            print(f"  updated  {path}{name}")
        else:
            print(f"  ok       {path}{name}")
        return obj
    obj = api("POST", path, body)
    print(f"  created  {path}{name}")
    return obj


# ---------------------------------------------------------------- tags
def setup_tags():
    print("Tags")
    ids = {}
    for name in ["receipt"]:
        # matching_algorithm 0 = none: Paperless must never auto-assign these
        ids[name] = upsert("tags/", name, {"matching_algorithm": 0, "match": ""})["id"]
    return ids


# ---------------------------------------------------------------- custom fields
CATEGORIES = [
    "Equipment & Supplies", "Bar Supplies", "Artist Fees",
    "Venue Rental", "Promotion & Advertising", "Software & Hosting",
]


def select_extra(field_name, labels):
    """Keep existing option ids (documents point at them), add missing labels."""
    existing = {o["name"]: o for o in all_items("custom_fields/")}
    current = (existing.get(field_name, {}).get("extra_data") or {}).get("select_options") or []
    by_label = {o["label"]: o for o in current}
    return {"select_options": [by_label.get(l, {"label": l}) for l in labels]}


# Who paid: comma-separated names in .env (PAID_BY), e.g. "Company,Alice,Bob"
PAID_BY = [n.strip() for n in ENV.get("PAID_BY", "Company").split(",") if n.strip()]


def setup_custom_fields():
    print("Custom fields")
    cad = {"default_currency": "CAD"}
    fields = [
        ("Total", "monetary", cad),
        ("GST", "monetary", cad),
        ("QST", "monetary", cad),
        ("Paid by", "select", select_extra("Paid by", PAID_BY)),
        ("Card last 4", "string", None),
        ("Category", "select", select_extra("Category", CATEGORIES)),
        ("Event", "string", None),
    ]
    ids = {}
    for name, dtype, extra in fields:
        body = {"data_type": dtype}
        if extra:
            body["extra_data"] = extra
        ids[name] = upsert("custom_fields/", name, body, compare_keys=["extra_data"] if extra else [])["id"]
    return ids


# ---------------------------------------------------------------- workflow
def setup_workflow(tag_ids):
    print("Workflow")
    body = {
        "order": 0,
        "enabled": True,
        "triggers": [{
            "type": 1,                 # consumption started
            "sources": [1, 2, 3, 4],   # consume folder, API upload, mail, web UI
            "filter_filename": "*",
        }],
        "actions": [{
            "type": 1,                 # assignment
            "assign_tags": [tag_ids["receipt"]],
        }],
    }
    existing = {o["name"]: o for o in all_items("workflows/")}
    name = "Receipts: tag for AI"  # name kept so re-runs update the existing workflow
    if name in existing:
        wf = existing[name]
        # replace in place, re-using trigger/action ids
        body["triggers"][0]["id"] = wf["triggers"][0]["id"]
        body["actions"][0]["id"] = wf["actions"][0]["id"]
        api("PATCH", f"workflows/{wf['id']}/", {"name": name, **body})
        print(f"  updated  workflows/{name}")
    else:
        api("POST", "workflows/", {"name": name, **body})
        print(f"  created  workflows/{name}")


# ---------------------------------------------------------------- mail
PROCESSED = "Paperless/Processed"


def ensure_imap_folder(host, port, user, password, folder):
    """Create the 'move to' folder (a label on Gmail) if it doesn't exist."""
    with imaplib.IMAP4_SSL(host, port) as m:
        m.login(user, password)
        typ, _ = m.select(f'"{folder}"', readonly=True)
        if typ == "OK":
            print(f"  ok       IMAP folder {folder}")
            return
        typ, data = m.create(f'"{folder}"')
        print(f"  created  IMAP folder {folder}" if typ == "OK" else f"  WARNING could not create {folder}: {data}")


def setup_mail(tag_ids):
    host = ENV.get("MAIL_IMAP_SERVER")
    if not host:
        print("Mail: MAIL_IMAP_SERVER not set in .env, skipped")
        return
    print("Mail")
    port = int(ENV.get("MAIL_IMAP_PORT", "993"))
    user, password = ENV["MAIL_USERNAME"], ENV["MAIL_PASSWORD"]
    folder = ENV.get("MAIL_FOLDER", "INBOX")
    ensure_imap_folder(host, port, user, password, PROCESSED)

    acct = upsert("mail_accounts/", "Receipts mailbox", {
        "imap_server": host,
        "imap_port": port,
        "imap_security": 2,        # SSL
        "username": user,
        "password": password,
        "character_set": "UTF-8",
        "account_type": 1,         # IMAP
    }, compare_keys=["imap_server", "imap_port", "username"])

    common = {
        "account": acct["id"],
        "folder": folder,
        "maximum_age": 30,
        "action": 2,                         # move to folder
        "action_parameter": PROCESSED,
        "assign_tags": [tag_ids["receipt"]],
        "assign_title_from": 1,              # subject (paperless-ai retitles anyway)
        "assign_correspondent_from": 1,      # none: the AI picks the vendor
        "enabled": True,
    }
    # Rule 1: real attachments only (inline logos/signatures are skipped by
    # attachment_type=1), PDFs and images only.
    upsert("mail_rules/", "Receipts 1: attachments", {
        **common,
        "order": 1,
        "consumption_scope": 1,              # attachments only
        "attachment_type": 1,                # only 'attachment' disposition, not inline
        "filter_attachment_filename_include": "*.pdf,*.jpg,*.jpeg,*.png,*.heic,*.webp",
        "filter_attachment_filename_exclude": "logo*,*signature*,image0*.png,outlook-*",
    }, compare_keys=["folder", "consumption_scope", "attachment_type", "action_parameter",
                     "filter_attachment_filename_include", "filter_attachment_filename_exclude"])
    # Rule 2: mails rule 1 didn't consume (no usable attachment, e.g. HTML
    # receipts from Amazon/Uber) are consumed whole as .eml -> PDF.
    # Paperless skips a mail already queued by rule 1 in the same run.
    upsert("mail_rules/", "Receipts 2: email body (.eml)", {
        **common,
        "order": 2,
        "consumption_scope": 2,              # full mail as .eml
        "attachment_type": 1,
    }, compare_keys=["folder", "consumption_scope", "action_parameter"])


def main():
    if not TOKEN:
        sys.exit("PAPERLESS_API_TOKEN is empty in .env")
    tags = setup_tags()
    setup_custom_fields()
    setup_workflow(tags)
    setup_mail(tags)
    print("done")


if __name__ == "__main__":
    main()
