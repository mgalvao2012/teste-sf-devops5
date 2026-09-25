#!/usr/bin/env bash
# One-shot GitHub CI configuration for an sf-devops project, via the gh CLI.
# Idempotent — safe to re-run. Sets up, for each major branch (integration/uat/production):
#   - repo secret  SFDX_AUTH_URL_<BRANCH>   (sourced from the locally-authenticated org, piped, never printed)
#   - GitHub Environment (uat/production get required reviewers from config/.sf-devops.yml; branch policy = own branch)
#   - branch protection, two profiles by whether the branch has approvers:
#       gated (uat/production): full status checks + N reviews + strict
#       auto-merge (integration, no approvers): only the deployability check + 0 reviews (so auto-merge.yml merges on green)
#   - repo variable SFDX_HARDIS_QUICK_DEPLOY=true
#   - auto-merge: enables the repo "Allow auto-merge" setting + sets the AUTOMERGE_PAT secret (from env AUTOMERGE_PAT)
#
# Secrets are REPO-LEVEL by design: check-deploy.yml validates on PRs (no `environment:` context, so it
# cannot read environment-scoped secrets). The deploy gate is enforced by Environments + required reviewers
# + deployment-branch-policies, not by secret scoping. (Forked PRs never receive repo secrets.)
#
# Usage: scripts/gh-setup.sh [--repo owner/name] [--private] [--no-create] [--yes]
#   --repo       target repo (default: origin of the current clone)
#   --private    if the repo must be created, create it private (default: public)
#                (public is the default so Environment required-reviewers work without a paid plan)
#   --no-create  do not create the repo; fail if it is not reachable
#   --no-push    do not push local major branches to the remote (protection stays pending for them)
#   --yes|-y     skip the confirmation prompt
# Prereqs: gh (authenticated), yq, jq, sf (with the per-branch org aliases already logged in).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

REPO=""; ASSUME_YES=0; VISIBILITY="public"; ALLOW_CREATE=1; ALLOW_PUSH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --public) VISIBILITY="public"; shift ;;
    --private) VISIBILITY="private"; shift ;;
    --no-create) ALLOW_CREATE=0; shift ;;
    --no-push) ALLOW_PUSH=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_cmd gh; require_cmd yq; require_cmd jq; require_cmd sf
need_config
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[[ -n "$REPO" ]] || die "Could not determine repo. Pass --repo owner/name (or run inside a GitHub clone)."
OWNER="${REPO%%/*}"

# Is the repo already reachable by the authenticated gh user? (404 = missing or no access.)
NEED_CREATE=0
if ! gh repo view "$REPO" --json nameWithOwner -q .nameWithOwner >/dev/null 2>&1; then
  [[ "$ALLOW_CREATE" == "1" ]] || die \
    "Repo '$REPO' not reachable and --no-create was given. Check: gh auth status / repo name."
  NEED_CREATE=1
fi

# Major branches come from the engine config; fall back to the standard three.
# (portable read loop — macOS ships bash 3.2, which has no `mapfile`)
BRANCHES=()
while IFS= read -r _b; do [[ -n "$_b" ]] && BRANCHES+=("$_b"); done \
  < <(yq -r '.majorBranches[]' config/.sfdx-hardis.yml 2>/dev/null || true)
[[ ${#BRANCHES[@]} -gt 0 ]] || BRANCHES=(integration uat production)

# Status checks that branch protection will require. Must match the job `name:` in each workflow.
# Override with: REQUIRED_CHECKS="Check-only Deployment to Major Org,MegaLinter" scripts/gh-setup.sh
IFS=',' read -r -a REQUIRED_CHECKS <<< "${REQUIRED_CHECKS:-Check-only Deployment to Major Org,MegaLinter}"
REVIEW_COUNT="${REVIEW_COUNT:-1}"
# The single deployability check required on the auto-merge branch (no reviewers). Must match
# the job `name:` in check-deploy.yml. On integration MegaLinter runs advisory (not blocking),
# so auto-merge only waits on deployability.
DEPLOY_CHECK="${DEPLOY_CHECK:-Check-only Deployment to Major Org}"

ENV_DEGRADED=0; CONFIG_CHANGED=0
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# Apply branch protection to a remote branch. Two profiles, chosen by whether the branch
# declares approvers in .sf-devops.yml:
#   - GATED (uat/production, has approvers): full Gate A checks + N reviews + strict (up-to-date).
#   - AUTO-MERGE (integration, no approvers): only the deployability check, 0 reviews, non-strict —
#     so auto-merge.yml can merge on green without a human and without waiting on MegaLinter.
# Warns (non-fatal) if the branch is not on the remote yet.
apply_protection() {
  local branch="$1" ctx rc strict
  if [[ "$(cfg_len ".environments.$branch.approvers")" -gt 0 ]]; then
    ctx="$(printf '%s\n' "${REQUIRED_CHECKS[@]}" | jq -R . | jq -sc .)"; rc="$REVIEW_COUNT"; strict=true
  else
    ctx="$(jq -nc --arg c "$DEPLOY_CHECK" '[$c]')"; rc=0; strict=false
  fi
  jq -nc --argjson ctx "$ctx" --argjson rc "$rc" --argjson strict "$strict" '{
    required_status_checks: {strict:$strict, contexts:$ctx},
    enforce_admins: false,
    required_pull_request_reviews: {required_approving_review_count:$rc, dismiss_stale_reviews:true},
    restrictions: null,
    required_linear_history: false,
    allow_force_pushes: false,
    allow_deletions: false
  }' | gh api -X PUT "repos/$REPO/branches/$branch/protection" \
        -H "Accept: application/vnd.github+json" --input - >/dev/null \
    && echo "  protection: $branch — PR + $(jq length <<<"$ctx") check(s) + $rc review(s)" \
    || warn "  protection: $branch failed (branch must exist on the remote first)"
}

# Resolve an approver spec (gh-team:[org/]slug | gh-user:login | login) to a reviewers-array element.
# Prints the JSON element on stdout; on failure prints a reason on stderr and returns 1 (so the
# CALLER can die in the parent process — a die here would only kill the $() subshell).
resolve_reviewer() {
  local a id spec org slug login
  a="$(trim "$1")"
  case "$a" in
    gh-team:*)
      spec="$(trim "${a#gh-team:}")"
      if [[ "$spec" == */* ]]; then org="$(trim "${spec%/*}")"; slug="$(trim "${spec#*/}")"; else org="$OWNER"; slug="$spec"; fi
      id="$(gh api "orgs/$org/teams/$slug" --jq '.id' 2>/dev/null)" \
        || { echo "team '$org/$slug' not found — teams require a GitHub org; a personal account has none, use gh-user:<login>" >&2; return 1; }
      jq -cn --argjson id "$id" '{type:"Team",id:$id}' ;;
    *)
      login="$(trim "${a#gh-user:}")"
      id="$(gh api "users/$login" --jq '.id' 2>/dev/null)" \
        || { echo "user '$login' not found" >&2; return 1; }
      jq -cn --argjson id "$id" '{type:"User",id:$id}' ;;
  esac
}

echo
log "Planned GitHub configuration"
if [[ "$NEED_CREATE" == "1" ]]; then
  echo "  repo:            $REPO  (WILL BE CREATED, $VISIBILITY — pushes current branch only)"
else
  echo "  repo:            $REPO"
fi
echo "  major branches:  ${BRANCHES[*]}"
echo "  required checks: gated branches (with approvers): ${REQUIRED_CHECKS[*]} + $REVIEW_COUNT review"
echo "                   auto-merge branch (no approvers): $DEPLOY_CHECK + 0 reviews"
echo "  secrets:         SFDX_AUTH_URL_<BRANCH> (repo-level, sourced from local sf orgs — never printed)"
echo "  branch config:   config/branches/.sfdx-hardis.<branch>.yml targetUsername/instanceUrl from sf org display"
echo "  environments:    uat/production with required reviewers from config/.sf-devops.yml; branch policy = own branch"
if [[ "$ALLOW_PUSH" == "1" ]]; then
  echo "  push:            local major branches → origin (triggers process-deploy, gated by Environments)"
else
  echo "  push:            skipped (--no-push)"
fi
echo "  variable:        SFDX_HARDIS_QUICK_DEPLOY=true"
echo "  auto-merge:      enable repo setting + set AUTOMERGE_PAT secret ($([[ -n "${AUTOMERGE_PAT:-}" ]] && echo "from env" || echo "NOT provided — will warn"))"
echo
if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "Apply this to '$REPO'? [y/N] " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] || { log "Aborted."; exit 0; }
fi

# 0) Create the repo if it doesn't exist yet. Pushes ONLY the current branch, so a merge/deploy
#    on uat/production is not triggered before the gates below are in place.
if [[ "$NEED_CREATE" == "1" ]]; then
  require_cmd git
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repo — cannot create/push '$REPO'."
  cur="$(git rev-parse --abbrev-ref HEAD)"
  log "Creating $REPO ($VISIBILITY); pushing current branch '$cur' only"
  gh repo create "$REPO" "--$VISIBILITY" >/dev/null || die "gh repo create failed for '$REPO'."
  remote_url="$(gh repo view "$REPO" --json url -q .url).git"
  if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$remote_url"; else git remote add origin "$remote_url"; fi
  git push -u origin "$cur"
  echo "  repo: created; branch '$cur' pushed"
fi

for branch in "${BRANCHES[@]}"; do
  BR_UP="$(upper "$branch")"
  log "── $branch ──"

  # 1) Auth-URL secret (repo-level) + branch config. Source from the local org alias in config/.sf-devops.yml.
  alias="$(cfg ".environments.$branch.orgAlias" "$branch")"
  # `sf org display --json` redacts the auth URL by default, so this JSON is safe to hold/parse.
  if org_json="$(sf org display -o "$alias" --json 2>/dev/null)"; then
    # Piped straight into gh — the credential is never echoed to the terminal or logs.
    if sf org auth show-sfdx-auth-url -o "$alias" --no-prompt --json | jq -r '.result.sfdxAuthUrl' | gh secret set "SFDX_AUTH_URL_$BR_UP" --repo "$REPO" >/dev/null; then
      echo "  secret: SFDX_AUTH_URL_$BR_UP set (from org alias '$alias')"
    else
      warn "  secret: failed to set SFDX_AUTH_URL_$BR_UP"
    fi
    # 1b) Fill the per-branch engine config with the resolved target user + instance (yq keeps comments).
    bc="config/branches/.sfdx-hardis.$branch.yml"
    username="$(jq -r '.result.username // empty' <<<"$org_json")"
    inst="$(jq -r '.result.instanceUrl // empty' <<<"$org_json")"
    if [[ -f "$bc" && -n "$username" ]]; then
      U="$username" yq -i '.targetUsername = strenv(U)' "$bc"
      if [[ -n "$inst" ]]; then I="$inst" yq -i '.instanceUrl = strenv(I)' "$bc"; fi
      echo "  config: $bc → targetUsername=$username"
      CONFIG_CHANGED=1
    elif [[ ! -f "$bc" ]]; then
      warn "  config: $bc not found — skipping targetUsername update"
    fi
  else
    # Production authenticates against login.salesforce.com; sandboxes (integration/uat/…) against test.salesforce.com.
    login_url="https://test.salesforce.com"; [[ "$branch" == "production" || "$branch" == "prod" ]] && login_url="https://login.salesforce.com"
    warn "  secret: org alias '$alias' not authenticated — skipping SFDX_AUTH_URL_$BR_UP + config (run: sf org login web --alias $alias --instance-url $login_url)"
  fi

  # 2) Environment (+ required reviewers for branches that declare approvers).
  reviewers="[]"
  n="$(cfg_len ".environments.$branch.approvers")"
  for ((i=0; i<n; i++)); do
    spec="$(trim "$(yq -r ".environments.$branch.approvers[$i]" "$CONFIG_FILE")")"
    [[ -z "$spec" || "$spec" == "null" ]] && continue
    [[ "$spec" == *CHANGE_ME* ]] && die "Approver placeholder '$spec' in config/.sf-devops.yml ($branch) — set a real GitHub team/user first."
    elem="$(resolve_reviewer "$spec")" \
      || die "Approver '$spec' ($branch) not resolvable. For a personal-account repo use gh-user:<login> (teams need an org)."
    reviewers="$(jq -c --argjson r "$elem" '. += [$r]' <<<"$reviewers")"
  done
  env_body="$(jq -nc --argjson revs "$reviewers" \
    '{wait_timer:0, reviewers:$revs, deployment_branch_policy:{protected_branches:false, custom_branch_policies:true}}')"
  if env_err="$( { printf '%s' "$env_body" | gh api -X PUT "repos/$REPO/environments/$branch" --input - >/dev/null; } 2>&1 )"; then
    # Restrict the environment (and its future env-scoped secrets) to its own branch.
    gh api -X POST "repos/$REPO/environments/$branch/deployment-branch-policies" -f name="$branch" >/dev/null 2>&1 || true
    echo "  environment: $branch ($([[ "$reviewers" == "[]" ]] && echo "no reviewers" || echo "$(jq length <<<"$reviewers") reviewer(s)"))"
  elif grep -qi 'billing plan' <<<"$env_err"; then
    # Free-plan private repos cannot set environment protection rules. Create a bare environment so
    # process-deploy.yml's `environment:` binding still resolves, but flag the missing reviewer gate.
    gh api -X PUT "repos/$REPO/environments/$branch" --input - <<<'{}' >/dev/null 2>&1 || true
    warn "  environment: '$branch' created WITHOUT reviewers/branch-policy (private repo on a free plan)."
    warn "               Enforce the gate by: gh repo edit $REPO --visibility public --accept-visibility-change-consequences"
    warn "               (or upgrade to GitHub Pro/Team/Enterprise), then re-run this script."
    ENV_DEGRADED=1
  else
    warn "  environment: '$branch' failed: $(tr -d '\n' <<<"$env_err")"
    ENV_DEGRADED=1
  fi
done

# 3) Push local major branches to the remote so their protection can be applied. Environments
#    (with reviewers) already exist above, so the process-deploy triggered by the push is gated.
if [[ "$ALLOW_PUSH" == "1" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "── push major branches ──"
  for branch in "${BRANCHES[@]}"; do
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      warn "  push: no local branch '$branch' — skipping"
    elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      echo "  push: '$branch' already on remote"
    else
      git push -u origin "$branch" >/dev/null 2>&1 \
        && echo "  push: '$branch' pushed (process-deploy will run, gated by the '$branch' Environment)" \
        || warn "  push: '$branch' failed"
    fi
  done
elif [[ "$ALLOW_PUSH" != "1" ]]; then
  log "── skipping branch push (--no-push) ──"
fi

# 4) Branch protection — applied after the push so uat/production exist on the remote.
log "── branch protection ──"
for branch in "${BRANCHES[@]}"; do
  apply_protection "$branch"
done

# 5) Quick Deploy repo variable.
gh variable set SFDX_HARDIS_QUICK_DEPLOY --repo "$REPO" --body "true" >/dev/null \
  && echo "  variable: SFDX_HARDIS_QUICK_DEPLOY=true" || warn "  variable: failed to set SFDX_HARDIS_QUICK_DEPLOY"

# 6) Auto-merge on green (developmentBranch = integration). Enable the repo setting and set the
#    PAT that auto-merge.yml uses. The PAT (repo+workflow scope) is REQUIRED because a merge done
#    with the built-in GITHUB_TOKEN does NOT trigger process-deploy.yml. Provide it via env — it is
#    piped straight into gh, never printed:  AUTOMERGE_PAT=<token> scripts/gh-setup.sh
log "── auto-merge ──"
gh repo edit "$REPO" --enable-auto-merge >/dev/null 2>&1 \
  && echo "  repo: auto-merge enabled" \
  || warn "  repo: could not enable auto-merge (need admin on $REPO)"
if [[ -n "${AUTOMERGE_PAT:-}" ]]; then
  printf '%s' "$AUTOMERGE_PAT" | gh secret set AUTOMERGE_PAT --repo "$REPO" >/dev/null \
    && echo "  secret: AUTOMERGE_PAT set (never printed)" \
    || warn "  secret: failed to set AUTOMERGE_PAT"
else
  warn "  secret: AUTOMERGE_PAT not provided — auto-merge.yml stays inert until it is set."
  warn "          Create a PAT with repo+workflow scope, then re-run: AUTOMERGE_PAT=<token> scripts/gh-setup.sh"
  warn "          (or set it once by hand: gh secret set AUTOMERGE_PAT --repo $REPO)"
fi

echo
log "Done. Verify: gh api repos/$REPO/branches/production/protection | jq '.required_status_checks'"
if [[ "$ALLOW_PUSH" != "1" ]]; then
  log "Branch protection only applies to branches on the remote. You used --no-push: push uat/production"
  log "when ready, then re-run (idempotent) to protect them — gates + Environments are already in place."
fi
log "Reviewers require a repo plan that supports Environment protection (public repos, or Pro/Team/Enterprise)."
if [[ "$CONFIG_CHANGED" == "1" ]]; then
  log "Branch configs were updated (targetUsername/instanceUrl) in the working tree — review & commit:"
  log "  git add config/branches && git commit -m 'chore: set per-branch target orgs' && git push"
fi
if [[ "$ENV_DEGRADED" == "1" ]]; then
  echo
  warn "One or more Environments were created WITHOUT the required-reviewer gate — promotion to UAT/prod is NOT protected."
  warn "Make the repo public (or upgrade the plan) and re-run before relying on this pipeline for real deploys."
  exit 3
fi
