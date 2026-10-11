#!/usr/bin/env bash
# bin/sheepr-route.sh - pick the kind, model and budget for a task.
#
# Usage:
#   sheepr-route.sh --type <T> --size <S> --risk <R> --repo <path>
#
# Prints one line: <kind> <model> <budget> <rule-name>
#
# Owns: reading the `routes` table and choosing its first matching rule. The
# table format is documented in the header of `routes` itself.
#
# Refuses (non-zero, reason on stderr):
#   - an unknown trait value, or a missing one. Every trait is required.
#   - a malformed routes file. A broken table is reported, not half-read.
#   - no matching rule.
#   - an unknown kind in the matched rule.
#   - a harness binary that is not installed. There is no fallback, ever: a
#     substitute harness is a decision the captain did not make.
#   - for codex, unless SHEEPR_CODEX_PROFILE is set and valid, and the model is
#     in the codex-cursor-bridge catalog. codex runs only through that bridge.
#
# Environment:
#   SHEEPR_ROUTES  the routes file. Default: routes at the sheepr root.
#   CODEX_HOME     where the bridge catalog lives, as
#                  $CODEX_HOME/cursor-bridge-models.json. Default: ~/.codex.
#
# The router fills only the gap the captain left. When the captain names a
# kind, a model or a budget, the supervisor passes theirs to spawn instead.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"

usage() {
  sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

TYPES="fix feature refactor research review docs"
SIZES="small medium large"
RISKS="low high"
RULE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]*$'
BUDGET_RE='^[1-9][0-9]*$'

in_list() {  # <word> <space-separated list>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

TYPE=''; SIZE=''; RISK=''; REPO_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --type) [ $# -ge 2 ] || die "--type needs a value"; TYPE=$2; shift 2 ;;
    --size) [ $# -ge 2 ] || die "--size needs a value"; SIZE=$2; shift 2 ;;
    --risk) [ $# -ge 2 ] || die "--risk needs a value"; RISK=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO_ARG=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- traits -----------------------------------------------------------------

[ -n "$TYPE" ] || die "--type is required (one of: $TYPES)"
in_list "$TYPE" "$TYPES" || die "unknown --type '$TYPE' (one of: $TYPES)"
[ -n "$SIZE" ] || die "--size is required (one of: $SIZES)"
in_list "$SIZE" "$SIZES" || die "unknown --size '$SIZE' (one of: $SIZES)"
[ -n "$RISK" ] || die "--risk is required (one of: $RISKS)"
in_list "$RISK" "$RISKS" || die "unknown --risk '$RISK' (one of: $RISKS)"
[ -n "$REPO_ARG" ] || die "--repo is required"
REPO=$(cd "$REPO_ARG" 2>/dev/null && pwd -P) || die "repo path not found: $REPO_ARG"

ROUTES=${SHEEPR_ROUTES:-$SHEEPR_ROOT/routes}
[ -f "$ROUTES" ] || die "routes file not found: $ROUTES"

# --- the table --------------------------------------------------------------

trim() {  # <text>
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# A trait column holds one known value or `*`.
check_column() {  # <line-no> <column> <value> <allowed>
  [ "$3" = '*' ] && return 0
  in_list "$3" "$4" || die "$ROUTES:$1: unknown $2 '$3' (one of: $4, *)"
}

MATCH=''
n=0
while IFS= read -r raw || [ -n "$raw" ]; do
  n=$((n + 1))
  line=$(trim "${raw%%#*}")
  [ -n "$line" ] || continue

  # Eight columns means exactly seven separators.
  seps=${line//[!|]/}
  [ "${#seps}" -eq 7 ] || die "$ROUTES:$n: want 8 columns separated by |, got $(( ${#seps} + 1 ))"

  IFS='|' read -r c_name c_type c_size c_risk c_glob c_kind c_model c_budget <<<"$line"
  c_name=$(trim "$c_name");   c_type=$(trim "$c_type")
  c_size=$(trim "$c_size");   c_risk=$(trim "$c_risk")
  c_glob=$(trim "$c_glob");   c_kind=$(trim "$c_kind")
  c_model=$(trim "$c_model"); c_budget=$(trim "$c_budget")

  # Every rule is checked, not only the one that matches: a broken rule below
  # the match is still a broken table, and it would surface on some other task.
  [[ $c_name =~ $RULE_NAME_RE ]] || die "$ROUTES:$n: rule name '$c_name' must match $RULE_NAME_RE"
  check_column "$n" type "$c_type" "$TYPES"
  check_column "$n" size "$c_size" "$SIZES"
  check_column "$n" risk "$c_risk" "$RISKS"
  [ -n "$c_glob" ] || die "$ROUTES:$n: repo-glob is empty (use * for any repo)"
  sheepr_kind_valid "$c_kind" || die "$ROUTES:$n: unknown kind '$c_kind' (one of: $SHEEPR_AGENT_KINDS)"
  sheepr_model_valid "$c_model" || die "$ROUTES:$n: model '$c_model' must match $SHEEPR_MODEL_RE"
  [[ $c_budget =~ $BUDGET_RE ]] || die "$ROUTES:$n: budget '$c_budget' must be a positive integer"

  [ -z "$MATCH" ] || continue
  { [ "$c_type" = '*' ] || [ "$c_type" = "$TYPE" ]; } || continue
  { [ "$c_size" = '*' ] || [ "$c_size" = "$SIZE" ]; } || continue
  { [ "$c_risk" = '*' ] || [ "$c_risk" = "$RISK" ]; } || continue
  # shellcheck disable=SC2053  # the right-hand side is a glob on purpose
  [[ $REPO == $c_glob ]] || continue
  MATCH="$c_kind $c_model $c_budget $c_name"
done <"$ROUTES"

[ -n "$MATCH" ] || die "no rule in $ROUTES matches type=$TYPE size=$SIZE risk=$RISK repo=$REPO"

read -r KIND MODEL BUDGET RULE <<<"$MATCH"

# --- the harness must exist -------------------------------------------------

BIN=$(sheepr_kind_bin "$KIND") || die "rule '$RULE': no binary known for kind '$KIND'"
command -v "$BIN" >/dev/null 2>&1 \
  || die "rule '$RULE' routes to $KIND, but '$BIN' is not installed. No fallback: install it or edit $ROUTES"

# --- codex runs only through codex-cursor-bridge ----------------------------

if [ "$KIND" = codex ]; then
  [ -n "${SHEEPR_CODEX_PROFILE:-}" ] \
    || die "rule '$RULE' routes to codex, but SHEEPR_CODEX_PROFILE is not set. codex runs only through codex-cursor-bridge"
  [[ $SHEEPR_CODEX_PROFILE =~ $SHEEPR_CODEX_PROFILE_RE ]] \
    || die "SHEEPR_CODEX_PROFILE must match $SHEEPR_CODEX_PROFILE_RE"
  sheepr_require_tools jq
  CATALOG="${CODEX_HOME:-$HOME/.codex}/cursor-bridge-models.json"
  [ -f "$CATALOG" ] || die "rule '$RULE' routes to codex, but the bridge catalog is missing: $CATALOG"
  jq -e '.models | type == "array"' "$CATALOG" >/dev/null 2>&1 \
    || die "the bridge catalog is not readable as {models: [...]}: $CATALOG"
  jq -e --arg m "$MODEL" 'any(.models[]; .slug == $m)' "$CATALOG" >/dev/null 2>&1 \
    || die "rule '$RULE' routes codex to model '$MODEL', which is not in the bridge catalog $CATALOG"
fi

printf '%s %s %s %s\n' "$KIND" "$MODEL" "$BUDGET" "$RULE"
