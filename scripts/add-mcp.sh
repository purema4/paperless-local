#!/usr/bin/env bash
# Registers the paperless-mcp server (docker compose service) in Claude Code,
# for this project only (local scope, stored in ~/.claude.json, not in the repo).
# The Paperless API token is read from .env and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
token=$(sed -n "s/^PAPERLESS_API_TOKEN=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" .env)
[ -n "$token" ] || { echo "PAPERLESS_API_TOKEN is empty in .env"; exit 1; }
claude mcp remove -s local paperless >/dev/null 2>&1 || true
claude mcp add -s local --transport http paperless http://localhost:3000/mcp \
  --header "Authorization: Bearer $token" >/dev/null
echo "paperless MCP server added (http://localhost:3000/mcp). Check with: claude mcp list"
