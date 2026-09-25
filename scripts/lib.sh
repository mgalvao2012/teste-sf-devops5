#!/usr/bin/env bash
# Shared helpers for sf-devops runtime scripts. Source this from other scripts.
set -euo pipefail

CONFIG_FILE="${SF_DEVOPS_CONFIG:-config/.sf-devops.yml}"

log()  { printf '\033[1;34m[sf-devops]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# cfg <yq-path> [default] — read a scalar from the project config.
cfg() {
  local path="$1" default="${2:-}" val
  val="$(yq -r "${path} // \"\"" "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ -z "$val" || "$val" == "null" ]]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# cfg_len <yq-path-to-array>
cfg_len() { yq -r "${1} | length" "$CONFIG_FILE" 2>/dev/null || echo 0; }

need_config() { [[ -f "$CONFIG_FILE" ]] || die "Config '$CONFIG_FILE' not found. Run bootstrap/adopt first."; }
