#!/usr/bin/env bash
# Seeds anonymized data into a target org via sfdx-hardis (wraps SFDMU).
# Usage: scripts/seed-data.sh <target-org-alias>
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need_config
target="${1:?target org alias required}"

dir="$(cfg '.dataSeeding.configDir' 'data/sfdmu')"
if [[ ! -f "$dir/export.json" ]]; then
  warn "No SFDMU plan at $dir/export.json — skipping seeding."
  exit 0
fi

log "Seeding data (SFDMU via sfdx-hardis): $dir -> $target"
# Anonymization comes from the updateWithMockData rules in export.json.
sf hardis:org:data:import --path "$dir" --target-org "$target"
log "Seeding complete."
