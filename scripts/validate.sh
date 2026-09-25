#!/usr/bin/env bash
# Gate A (fast, per-PR): check-only smart deploy via sfdx-hardis.
# hardis handles delta computation, impacted-test selection, coverage and destructive changes.
# The CI equivalent is check-deploy.yml (Gate A on PRs); this script is the local check.
# Usage: scripts/validate.sh <target-org-alias>
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need_config
target="${1:?target org alias required}"

log "Gate A: check-only smart deploy against '$target'"
sf hardis:project:deploy:smart --check --target-org "$target"
log "Gate A passed."
