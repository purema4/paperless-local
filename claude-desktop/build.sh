#!/usr/bin/env bash
# Builds paperless.mcpb, a Claude Desktop extension (double-click to install).
# server/index.js forwards the tools of the remote paperless-mcp server and adds
# upload_local_files (sends files from the computer straight to the Paperless API).
#
# Usage:  claude-desktop/build.sh https://<server>.ts.net:10000/mcp
# Output: claude-desktop/dist/paperless.mcpb  (no secret inside: the token is
#         asked at install time and kept in the OS keychain by Claude Desktop)
set -euo pipefail
URL="${1:?Usage: $0 MCP_URL   e.g. https://paperless.example.ts.net:10000/mcp}"
HERE=$(cd "$(dirname "$0")" && pwd)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

python3 - "$HERE/manifest.json" "$STAGE/manifest.json" "$URL" <<'PY'
import json, sys
src, dst, url = sys.argv[1:]
m = json.load(open(src, encoding="utf-8"))
m["user_config"]["server_url"]["default"] = url
json.dump(m, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

cp -r "$HERE/server" "$HERE/package.json" "$STAGE/"
cd "$STAGE"
npm install --omit=dev --no-audit --no-fund --silent
npx -y @anthropic-ai/mcpb@2.1.2 validate manifest.json
mkdir -p "$HERE/dist"
npx -y @anthropic-ai/mcpb@2.1.2 pack . "$HERE/dist/paperless.mcpb"
echo "Built $HERE/dist/paperless.mcpb"
