#!/usr/bin/env bash
# Creates a Paperless account for an employee (group "employees": view/add/change,
# no delete) and prints its API token and a web password ONCE.
# The token goes into the Claude Desktop extension (claude-desktop/).
# Run setup.py first (it creates the group).
#
#   scripts/add-employee.sh USERNAME            create (or reset token/password)
#   scripts/add-employee.sh --remove USERNAME   deactivate the account and revoke its token
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=add
[[ "${1:-}" == --remove ]] && { MODE=remove; shift; }
NAME="${1:?Usage: $0 [--remove] USERNAME}"
[[ "$NAME" =~ ^[A-Za-z0-9._-]{2,64}$ ]] || { echo "Invalid username: $NAME"; exit 1; }

docker compose exec -T -e EMP_NAME="$NAME" -e EMP_MODE="$MODE" paperless \
  python3 manage.py shell <<'PY'
import os, secrets
from django.contrib.auth.models import User, Group
from rest_framework.authtoken.models import Token

name, mode = os.environ["EMP_NAME"], os.environ["EMP_MODE"]
if mode == "remove":
    u = User.objects.filter(username=name).first()
    if not u:
        raise SystemExit(f"No user {name}")
    Token.objects.filter(user=u).delete()
    u.is_active = False
    u.set_unusable_password()
    u.save()
    print(f"{name}: deactivated, token revoked (documents are kept)")
    raise SystemExit(0)

group = Group.objects.filter(name="employees").first()
if not group:
    raise SystemExit("Group 'employees' missing: run python3 setup.py first")
u, created = User.objects.get_or_create(username=name)
if u.is_superuser:
    raise SystemExit(f"{name} is an admin account, not touching it")
password = secrets.token_urlsafe(12)
u.set_password(password)
u.is_active, u.is_staff = True, False
u.save()
u.groups.add(group)
Token.objects.filter(user=u).delete()
token = Token.objects.create(user=u)
print(f"{'Created' if created else 'Reset'} {name}")
print(f"  Token for Claude Desktop : {token.key}")
print(f"  Web password (Paperless) : {password}")
print("Shown once: send them privately.")
PY
