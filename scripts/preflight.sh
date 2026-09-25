#!/usr/bin/env bash
# Verifies prerequisites before any org operation. Fails fast, fails closed.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need_config

log "Preflight: tooling"
require_cmd sf
require_cmd git
require_cmd yq

log "Preflight: config is a real project (not the template)"
name="$(cfg '.project.name')"
[[ -n "$name" && "$name" != "CHANGE_ME" ]] \
  || die "project.name is unset/placeholder ('$name'). This looks like the template config — run preflight from an onboarded project (after bootstrap.sh/adopt.sh), with config/.sf-devops.yml filled in."

log "Preflight: sf plugins"
plugins="$(sf plugins 2>/dev/null || true)"
grep -q 'sfdx-hardis' <<<"$plugins" || warn "sfdx-hardis not installed: sf plugins install sfdx-hardis"
grep -q 'sfdmu'       <<<"$plugins" || warn "sfdmu not installed: sf plugins install sfdmu"

log "Preflight: Dev Hub"
if [[ "$(cfg '.devhub.required' 'true')" == "true" ]]; then
  devhub="$(cfg '.devhub.alias' 'DevHub')"
  # 1. alias must resolve to a connected org
  sf org display --target-org "$devhub" >/dev/null 2>&1 \
    || die "Dev Hub alias '$devhub' does not resolve / is not authenticated. Run: sf org login web --set-default-dev-hub --alias $devhub"
  # 2. that org must ACTUALLY be a Dev Hub (ScratchOrgInfo is queryable only when Dev Hub is enabled)
  sf data query --query "SELECT Id FROM ScratchOrgInfo LIMIT 1" --target-org "$devhub" >/dev/null 2>&1 \
    || die "Org '$devhub' is connected but Dev Hub is NOT enabled (cannot query ScratchOrgInfo). Enable it: Setup > Dev Hub > Enable Dev Hub."
fi

log "Preflight: approval gates (fail-closed)"
for env in uat production; do
  n="$(cfg_len ".environments.${env}.approvers")"
  [[ "$n" -gt 0 ]] || die "No approvers defined for '${env}' in $CONFIG_FILE. Promotion is fail-closed."
  # reject placeholders — a CHANGE_ME approver is not a real reviewer
  for i in $(seq 0 $((n - 1))); do
    a="$(cfg ".environments.${env}.approvers[$i]")"
    [[ "$a" != *CHANGE_ME* ]] \
      || die "Approver '$a' for '${env}' is a placeholder. Set the real GitHub team/user in $CONFIG_FILE."
  done
done

log "Preflight OK."
