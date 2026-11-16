#!/usr/bin/env bash
# Build and install ghpr for GitHub into the running cmux app.
set -euo pipefail

usage() {
  echo "Usage: $0 [--surface <id|ref>]"
  echo "Build and install the userscript; optionally reload one cmux browser surface."
  echo "Without --surface, existing pages are left untouched until their next navigation."
  echo "Requires: node, jq, and cmux on PATH; cmux must be running."
}

surface=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --surface)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* || -n "$surface" ]]; then
        usage >&2
        exit 1
      fi
      surface="$2"
      shift 2
      ;;
    *) usage >&2; exit 1 ;;
  esac
done

for dependency in node jq cmux; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Error: required command not found: $dependency" >&2
    exit 1
  fi
done

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
node "$repo_dir/browser/build-userscript.mjs"
params="$(jq -Rs '{script: ., id: "ghpr-for-github", enabled: true}' "$repo_dir/browser/ghpr.user.js")"
cmux rpc browser.userscript.install "$params"

if [[ -n "$surface" ]]; then
  cmux browser --surface "$surface" reload
else
  echo "Installed. Reload a GitHub tab to activate the updated userscript on that page."
fi
