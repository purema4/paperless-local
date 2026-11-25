#!/usr/bin/env bash
# Usage: scripts/set-secret.sh NAME   -> asks for the value (hidden) and writes NAME=value into .env
set -euo pipefail
cd "$(dirname "$0")/.."
name="$1"
read -rsp "Value for $name (input hidden): " value; echo
[ -n "$value" ] || { echo "empty, nothing changed"; exit 1; }
python3 - "$name" "$value" <<'PY'
import sys, re
name, value = sys.argv[1], sys.argv[2]
if any(c in value for c in "'\n"): value = value.replace("'", "")
line = f"{name}='{value}'" if any(c in value for c in ' "{}#$') else f"{name}={value}"
s = open(".env").read()
s, n = re.subn(rf"^{re.escape(name)}=.*$", lambda m: line, s, flags=re.M)
if not n: s += ("" if s.endswith("\n") else "\n") + line + "\n"
open(".env", "w").write(s)
PY
echo "$name saved in .env"
