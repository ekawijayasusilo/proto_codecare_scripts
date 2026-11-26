#!/usr/bin/env bash
# Offline test: runs setup-github-repo.sh against a stub `gh` and checks the ruleset payloads it sends.
# Needs bash and jq (the stub uses jq in place of gh's built-in --jq).
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/setup-github-repo.sh"
FAILS=0

# Stub gh: answers GETs from $WORK/fixtures/<endpoint>.json, saves --input bodies to $WORK/<METHOD>-<endpoint>.json.
gh() {
  [[ $1 == api ]] || return 0
  shift
  local method=GET filter="" endpoint="" input=false
  while (($#)); do
    case $1 in
      -X) method=$2; shift ;;
      --jq) filter=$2; shift ;;
      --input) input=true; shift ;;
      -f | -F) shift ;;
      --*) ;;
      *) endpoint=$1 ;;
    esac
    shift
  done
  local key=${endpoint//[\/?=&]/_}
  if $input; then cat >"$WORK/$method-$key.json"; return 0; fi
  [[ $method == GET && -f $WORK/fixtures/$key.json ]] || return 0
  if [[ -n $filter ]]; then jq -r "$filter" "$WORK/fixtures/$key.json" | tr -d '\r'; else cat "$WORK/fixtures/$key.json"; fi
}
export -f gh

# new_case NAME: fresh work dir with a public, user-owned repo o/r the caller administers.
new_case() {
  CASE=$1
  WORK=$(mktemp -d)
  export WORK
  mkdir "$WORK/fixtures"
  echo '{"owner": {"type": "User"}, "default_branch": "main", "visibility": "public", "permissions": {"admin": true}}' \
    >"$WORK/fixtures/repos_o_r.json"
  echo '[]' >"$WORK/fixtures/repos_o_r_rulesets_includes_parents_false.json"
}

# existing_ruleset JSON: make o/r already have ruleset id 1 named main-branch with JSON as its rules.
existing_ruleset() {
  echo '[{"id": 1, "name": "main-branch"}]' >"$WORK/fixtures/repos_o_r_rulesets_includes_parents_false.json"
  echo "{\"id\": 1, \"name\": \"main-branch\", \"rules\": $1}" >"$WORK/fixtures/repos_o_r_rulesets_1.json"
}

run() { bash "$SCRIPT" --repo o/r --yes "$@" </dev/null >"$WORK/out" 2>&1 || { cat "$WORK/out"; return 1; }; }

check() { # DESC JQ_BOOL FILE
  if jq -e "$2" "$3" >/dev/null 2>&1; then
    echo "ok   $CASE: $1"
  else
    echo "FAIL $CASE: $1"
    FAILS=$((FAILS + 1))
  fi
}

check_out() { # DESC TEXT
  if grep -qF "$2" "$WORK/out"; then echo "ok   $CASE: $1"; else echo "FAIL $CASE: $1" && FAILS=$((FAILS + 1)); fi
}

MANUAL_RULES='[
  {"type": "deletion"},
  {"type": "non_fast_forward"},
  {"type": "pull_request", "parameters": {"required_approving_review_count": 0,
    "require_extra_approval_for_unattributed_changes": true, "allowed_merge_methods": ["squash", "merge"]}},
  {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false,
    "required_status_checks": [{"context": "build / build", "integration_id": 15368}]}}
]'

new_case "create"
run
check "POSTs only the script's rules" '.rules | map(.type) == ["deletion", "non_fast_forward", "pull_request"]' \
  "$WORK/POST-repos_o_r_rulesets.json"

new_case "re-run"
existing_ruleset "$MANUAL_RULES"
run --approvals 1
PUT=$WORK/PUT-repos_o_r_rulesets_1.json
check "keeps manual required checks" \
  '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] == ["build / build"]' "$PUT"
check "flags win over existing parameters" '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count == 1' "$PUT"
check "arrays from the script replace existing ones" '.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods == ["squash"]' "$PUT"
check "keeps parameters the script doesn't send" \
  '.rules[] | select(.type == "pull_request") | .parameters.require_extra_approval_for_unattributed_changes == true' "$PUT"
check_out "reports kept rules" "Kept rules not set by this script: required_status_checks"

((FAILS == 0)) || { echo "$FAILS check(s) failed"; exit 1; }
echo "all checks passed"
