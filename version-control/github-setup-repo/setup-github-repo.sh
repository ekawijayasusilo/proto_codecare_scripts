#!/usr/bin/env bash
# Apply opinionated settings to an existing public GitHub repository.
# Requires: gh, authenticated as a repo admin. Safe to re-run.
set -Eeuo pipefail

MAIN_RULESET="main-branch"
TAG_RULESET="release-tags"
ADMIN_BYPASS='[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]'

usage() {
  cat <<'EOF'
Usage: setup-github-repo.sh --repo OWNER/NAME [options]

Options not given on the command line are asked interactively.
With --yes (or no terminal) their defaults are used instead.

  --repo OWNER/NAME          Target repository (required, no default)
  --[no-]template            Mark as template repository            (default: no)
  --approvals N              Required PR approvals, 0-10             (default: 0)
  --[no-]codeowners          Require review from code owners         (default: no)
  --[no-]dependabot          Dependency graph + Dependabot alerts    (default: yes)
                             + security updates
  --[no-]secret-scanning     Secret scanning + push protection       (default: yes)
  --[no-]codeql              CodeQL default setup                    (default: no)
  --[no-]tag-protection      Protect v* tags from delete/move        (default: no)
  --secrets-file PATH        Upload secrets/variables (format: .env.github.example)
  -y, --yes                  Don't prompt
  -h, --help                 Show this help

For optional features, "no" means "leave as is", not "disable".
EOF
}

die() { echo "✖ $*" >&2; exit 1; }
warn() { echo "⚠ $*" >&2; }
step() { echo "▶ $*"; }
trap 'echo "✖ Failed at line $LINENO. Fix the error above and re-run (safe to re-run)." >&2' ERR

# ask VAR PROMPT DEFAULT: keep VAR if already set, else prompt (or take default with --yes).
ask() {
  [[ -n ${!1} ]] && return 0
  local ans=""
  if ! $YES; then read -rp "$2 [$3] " ans; fi
  printf -v "$1" %s "${ans:-$3}"
}

ask_bool() {
  ask "$@"
  case ${!1} in
    [yY] | [yY][eE][sS] | true) printf -v "$1" true ;;
    [nN] | [nN][oO] | false) printf -v "$1" false ;;
    *) die "$1: expected y or n, got '${!1}'" ;;
  esac
}

# --- secrets file -----------------------------------------------------------
# Sections like [actions.secret] hold dotenv lines; each section is piped to `gh ... -f -`.
SECTIONS=()
BODIES=()

# Sets ARGS (gh subcommand) and ENV_NAME for a section; returns 1 if the section is unknown.
section_args() {
  ENV_NAME=""
  case $1 in
    actions.secret) ARGS=(secret set --app actions) ;;
    actions.var) ARGS=(variable set) ;;
    dependabot.secret) ARGS=(secret set --app dependabot) ;;
    codespaces.secret) ARGS=(secret set --app codespaces) ;;
    env:*.secret | env:*.var)
      ENV_NAME=${1#env:}
      ENV_NAME=${ENV_NAME%.*}
      [[ $ENV_NAME =~ ^[A-Za-z0-9._-]+$ ]] || return 1
      if [[ $1 == *.secret ]]; then ARGS=(secret set --env "$ENV_NAME"); else ARGS=(variable set --env "$ENV_NAME"); fi
      ;;
    *) return 1 ;;
  esac
}

add_section() {
  # Skip sections with only comments/blank lines; gh rejects an empty file.
  if grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' <<<"$2"; then
    SECTIONS+=("$1")
    BODIES+=("$2")
  fi
}

parse_secrets_file() {
  local file=$1 line n=0 section="" body=""
  local header='^\[([^]]*)\][[:space:]]*(#.*)?$'
  [[ -f $file ]] || die "secrets file not found: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ $line =~ $header ]]; then
      if [[ -n $section ]]; then add_section "$section" "$body"; fi
      section=${BASH_REMATCH[1]}
      body=""
      section_args "$section" || die "$file:$n: unknown section [$section]"
    elif [[ -z $section ]]; then
      [[ $line =~ ^[[:space:]]*(#|$) ]] || die "$file:$n: entry outside a [section]"
    else
      body+=$line$'\n'
    fi
  done <"$file"
  if [[ -n $section ]]; then add_section "$section" "$body"; fi

  local dir
  dir=$(dirname "$file")
  if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null && ! git -C "$dir" check-ignore -q "$(basename "$file")"; then
    warn "$file is inside a git repo and NOT gitignored. Don't commit it."
  fi
}

# --- rulesets ---------------------------------------------------------------
upsert_ruleset() { # NAME JSON
  local id
  id=$(gh api --paginate "repos/$REPO/rulesets?includes_parents=false" --jq ".[] | select(.name == \"$1\") | .id")
  if [[ -n $id ]]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input - --silent <<<"$2"
  else
    gh api -X POST "repos/$REPO/rulesets" --input - --silent <<<"$2"
  fi
}

main_ruleset() { # WITH_MERGE_QUEUE(true|false)
  # Stale-approval guards only mean something when approvals are required;
  # with 0 approvals they could block a solo maintainer.
  local guards=false merge_queue=""
  if ((APPROVALS > 0)); then guards=true; fi
  if $1; then
    # GitHub's UI defaults.
    merge_queue=',
    {"type": "merge_queue", "parameters": {
      "merge_method": "SQUASH", "grouping_strategy": "ALLGREEN",
      "max_entries_to_build": 5, "min_entries_to_merge": 1, "max_entries_to_merge": 5,
      "min_entries_to_merge_wait_minutes": 5, "check_response_timeout_minutes": 60}}'
  fi
  cat <<EOF
{
  "name": "$MAIN_RULESET",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": $ADMIN_BYPASS,
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": $APPROVALS,
      "require_code_owner_review": $CODEOWNERS,
      "dismiss_stale_reviews_on_push": $guards,
      "require_last_push_approval": $guards,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["squash"]}}$merge_queue
  ]
}
EOF
}

tag_ruleset() {
  cat <<EOF
{
  "name": "$TAG_RULESET",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "bypass_actors": $ADMIN_BYPASS,
  "rules": [{"type": "deletion"}, {"type": "update"}, {"type": "non_fast_forward"}]
}
EOF
}

# --- steps ------------------------------------------------------------------
setup_default_branch() {
  step "Default branch → main"
  if [[ $DEFAULT_BRANCH == main ]]; then
    return 0
  elif gh api "repos/$REPO/branches/main" --silent 2>/dev/null; then
    gh api -X PATCH "repos/$REPO" -f default_branch=main --silent
  elif gh api "repos/$REPO/branches/$DEFAULT_BRANCH" --silent 2>/dev/null; then
    gh api -X POST "repos/$REPO/branches/$DEFAULT_BRANCH/rename" -f new_name=main --silent
    echo "  Renamed $DEFAULT_BRANCH → main. Update local clones with:"
    echo "  git branch -m $DEFAULT_BRANCH main && git fetch origin && git branch -u origin/main main && git remote set-head origin -a"
  else
    warn "Repo has no commits yet. Push a 'main' branch, then re-run."
  fi
}

setup_main_ruleset() {
  step "Ruleset '$MAIN_RULESET'"
  # Merge queue only exists for org-owned repos; fall back silently-ish if the org lacks it.
  if [[ $OWNER_TYPE == Organization ]] && upsert_ruleset "$MAIN_RULESET" "$(main_ruleset true)" 2>/dev/null; then
    echo "  Merge queue enabled. CI workflows must also trigger on 'merge_group'."
    return 0
  fi
  if [[ $OWNER_TYPE == Organization ]]; then warn "Merge queue not available for this org; skipped."; fi
  upsert_ruleset "$MAIN_RULESET" "$(main_ruleset false)"
}

main() {
  REPO="" TEMPLATE="" APPROVALS="" CODEOWNERS="" DEPENDABOT="" SECRET_SCANNING="" CODEQL="" TAG_PROTECTION="" SECRETS_FILE="" YES=false
  local secrets_flag=false
  while (($#)); do
    case $1 in
      --repo) REPO=${2:?--repo needs a value}; shift ;;
      --template) TEMPLATE=true ;;
      --no-template) TEMPLATE=false ;;
      --approvals) APPROVALS=${2:?--approvals needs a value}; shift ;;
      --codeowners) CODEOWNERS=true ;;
      --no-codeowners) CODEOWNERS=false ;;
      --dependabot) DEPENDABOT=true ;;
      --no-dependabot) DEPENDABOT=false ;;
      --secret-scanning) SECRET_SCANNING=true ;;
      --no-secret-scanning) SECRET_SCANNING=false ;;
      --codeql) CODEQL=true ;;
      --no-codeql) CODEQL=false ;;
      --tag-protection) TAG_PROTECTION=true ;;
      --no-tag-protection) TAG_PROTECTION=false ;;
      --secrets-file) SECRETS_FILE=${2:?--secrets-file needs a value}; secrets_flag=true; shift ;;
      -y | --yes) YES=true ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
  [[ -t 0 ]] || YES=true

  command -v gh >/dev/null || die "gh CLI not found: https://cli.github.com"

  # Repo first: it's the one input with no default, and everything else depends on it.
  if [[ -z $REPO ]]; then
    $YES && die "--repo OWNER/NAME is required"
    read -rp "Repository (OWNER/NAME): " REPO
  fi
  [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository '$REPO', expected OWNER/NAME"
  local info is_admin visibility
  info=$(gh api "repos/$REPO" --jq '[.owner.type, .default_branch, .visibility, .permissions.admin] | @tsv') ||
    die "cannot read $REPO (does it exist? is gh logged in?)"
  IFS=$'\t' read -r OWNER_TYPE DEFAULT_BRANCH visibility is_admin <<<"$info"
  [[ $is_admin == true ]] || die "you need admin access to $REPO"
  [[ $visibility == public ]] || warn "$REPO is $visibility; this script targets public repos and some steps may fail."

  ask_bool TEMPLATE "Template repository? (y/n)" n
  ask APPROVALS "Required PR approvals (0-10)?" 0
  [[ $APPROVALS =~ ^([0-9]|10)$ ]] || die "--approvals must be 0-10, got '$APPROVALS'"
  ask_bool CODEOWNERS "Require code owner review? (y/n)" n
  ask_bool DEPENDABOT "Enable dependency graph + Dependabot alerts + security updates? (y/n)" y
  ask_bool SECRET_SCANNING "Enable secret scanning + push protection? (y/n)" y
  ask_bool CODEQL "Enable CodeQL default setup? (y/n)" n
  ask_bool TAG_PROTECTION "Protect v* release tags? (y/n)" n
  if ! $secrets_flag; then ask SECRETS_FILE "Secrets file path (blank to skip)?" ""; fi
  # Validate the whole file before touching the repo, so a typo can't cause a half-applied run.
  if [[ -n $SECRETS_FILE ]]; then parse_secrets_file "$SECRETS_FILE"; fi

  if ! $YES; then
    local ok
    read -rp "Apply settings to $REPO? (y/n) [y] " ok
    [[ ${ok:-y} == [yY]* ]] || die "aborted"
  fi

  step "Repository settings"
  gh api -X PATCH "repos/$REPO" --silent \
    -F is_template="$TEMPLATE" \
    -F allow_merge_commit=false -F allow_rebase_merge=false -F allow_squash_merge=true \
    -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK \
    -F allow_update_branch=true -F allow_auto_merge=true -F delete_branch_on_merge=true

  setup_default_branch
  setup_main_ruleset

  if $TAG_PROTECTION; then
    step "Ruleset '$TAG_RULESET'"
    upsert_ruleset "$TAG_RULESET" "$(tag_ruleset)"
  fi

  step "Actions: read-only GITHUB_TOKEN, may create/approve PRs"
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" --silent \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true

  step "Private vulnerability reporting"
  gh api -X PUT "repos/$REPO/private-vulnerability-reporting" --silent

  if $DEPENDABOT; then
    step "Dependency graph + Dependabot alerts + security updates"
    # vulnerability-alerts enables alerts and the dependency graph together (no separate API switch);
    # it must come before automated-security-fixes.
    gh api -X PUT "repos/$REPO/vulnerability-alerts" --silent
    gh api -X PUT "repos/$REPO/automated-security-fixes" --silent
    gh api "repos/$REPO/vulnerability-alerts" --silent ||
      warn "Dependency graph/Dependabot alerts still look disabled. Check https://github.com/$REPO/settings/security_analysis"
  fi

  if $SECRET_SCANNING; then
    step "Secret scanning + push protection"
    gh api -X PATCH "repos/$REPO" --input - --silent <<<'{"security_and_analysis": {
      "secret_scanning": {"status": "enabled"},
      "secret_scanning_push_protection": {"status": "enabled"}}}'
  fi

  if $CODEQL; then
    step "CodeQL default setup"
    gh api -X PATCH "repos/$REPO/code-scanning/default-setup" -f state=configured --silent ||
      warn "CodeQL setup failed (no supported language in the repo yet?). Re-run after pushing code."
  fi

  local i
  for ((i = 0; i < ${#SECTIONS[@]}; i++)); do
    section_args "${SECTIONS[i]}"
    step "Secrets/variables [${SECTIONS[i]}]"
    if [[ -n $ENV_NAME ]]; then gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --silent; fi
    gh "${ARGS[@]}" --repo "$REPO" -f - <<<"${BODIES[i]}"
  done

  echo "✔ Done: https://github.com/$REPO/settings"
}

main "$@"
