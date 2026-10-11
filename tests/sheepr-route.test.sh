#!/usr/bin/env bash
# tests/sheepr-route.test.sh - the router: matching order, wildcards, every
# refusal, and the codex bridge catalog check.
#
# Every test runs against a fixture routes file and a fixture PATH, so the
# result never depends on which harnesses this machine has installed. The
# shipped `routes` file is checked last, only for being well formed.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

begin

ROUTES_FILE="$SHEEPR_HOME/routes"
export SHEEPR_ROUTES=$ROUTES_FILE

# A PATH holding only fake harness binaries plus the tools the router needs.
# Removing a fake from it is how "not installed" is tested.
FAKEBIN="$SHEEPR_HOME/bin"
mkdir -p "$FAKEBIN"
for t in bash jq; do ln -s "$(command -v "$t")" "$FAKEBIN/$t"; done
for b in cursor-agent claude codex; do
  printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/$b"; chmod +x "$FAKEBIN/$b"
done
ROUTE_PATH="$FAKEBIN:/usr/bin:/bin"

# A codex-cursor-bridge catalog, the same shape the bridge writes.
export CODEX_HOME="$SHEEPR_HOME/codex"
mkdir -p "$CODEX_HOME"
CATALOG="$CODEX_HOME/cursor-bridge-models.json"
printf '{"models":[{"slug":"composer-2.5","display_name":"Composer 2.5"},{"slug":"gpt-5.5"}]}\n' >"$CATALOG"
unset SHEEPR_CODEX_PROFILE

REPO_A="$SHEEPR_HOME/repos/alpha"
REPO_B="$SHEEPR_HOME/repos/beta"
mkdir -p "$REPO_A" "$REPO_B"

route() { PATH=$ROUTE_PATH "$SHEEPR_ROOT/bin/sheepr-route.sh" "$@" 2>&1; }
route_t() {  # <type> <size> <risk> [repo]
  route --type "$1" --size "$2" --risk "$3" --repo "${4:-$REPO_A}"
}

# Assert a refusal: non-zero exit, and stderr carries <needle>.
refused() {  # <needle> <description> <command...>
  local needle=$1 desc=$2 out rc
  shift 2
  out=$("$@"); rc=$?
  if [ "$rc" -ne 0 ]; then ok "$desc"; else fail "$desc" "exit 0, printed: $out"; fi
  case "$out" in *"$needle"*) ok "  and says: $needle" ;;
    *) fail "  and says: $needle" "got: $out" ;; esac
}

cat >"$ROUTES_FILE" <<'EOF'
# a comment line

risky   | *    | *     | high | *        | claude | claude-opus-5-5   | 3000000   # trailing comment
beta    | *    | *     | *    | */beta   | cursor | composer-2.5      | 100
tiny    | docs | small | low  | *        | cursor | composer-2.5      | 200000
fixes   | fix  | *     | *    | *        | claude | claude-sonnet-5-5 | 500000
default | *    | *     | *    | *        | claude | claude-sonnet-5-5 | 1000000
EOF

# --- matching ---------------------------------------------------------------

is "$(route_t docs small low)" 'cursor composer-2.5 200000 tiny' 'an exact rule matches'
is "$(route_t docs small high)" 'claude claude-opus-5-5 3000000 risky' \
  'the first match wins over a later, more specific one'
is "$(route_t docs medium low)" 'claude claude-sonnet-5-5 1000000 default' \
  'a near miss falls through to the catch-all'
is "$(route_t fix large low)" 'claude claude-sonnet-5-5 500000 fixes' '`*` matches any size and risk'
is "$(route_t docs small low "$REPO_B")" 'cursor composer-2.5 100 beta' \
  'the repo glob matches the repository path'
is "$(route_t docs small low "$REPO_B/")" 'cursor composer-2.5 100 beta' \
  'a trailing slash on --repo does not defeat the glob'

# --- refusals: traits -------------------------------------------------------

refused "unknown --type 'bug'" 'an unknown type is refused' route_t bug small low
refused "unknown --size 'tiny'" 'an unknown size is refused' route_t docs tiny low
refused "unknown --risk 'medium'" 'an unknown risk is refused' route_t docs small medium
refused '--type is required' 'a missing trait is refused' \
  route --size small --risk low --repo "$REPO_A"
refused 'repo path not found' 'a missing repository is refused' \
  route_t docs small low "$SHEEPR_HOME/nope"
refused '--risk needs a value' 'a flag with no value is refused' \
  route --type docs --size small --risk

# --- refusals: no rule ------------------------------------------------------

cat >"$ROUTES_FILE" <<'EOF'
only-docs | docs | * | * | * | claude | claude-sonnet-5-5 | 1000
EOF
refused 'no rule' 'no matching rule is refused, not defaulted' route_t fix small low

# --- refusals: the table ----------------------------------------------------

bad_table() {  # <rule-line> <needle> <description>
  printf '%s\n' "$1" >"$ROUTES_FILE"
  refused "$2" "$3" route_t docs small low
}
bad_table 'x | docs | small | low | * | gemini | m1 | 1' "unknown kind 'gemini'" \
  'an unknown kind is refused'
bad_table 'x | docs | small | low | * | claude | m1' 'want 8 columns' \
  'a rule with a missing column is refused'
bad_table 'x | doc | small | low | * | claude | m1 | 1' "unknown type 'doc'" \
  'an unknown trait value in the table is refused'
bad_table 'x | docs | small | low | * | claude | -m | 1' "model '-m'" \
  'a model that reads as a flag is refused'
bad_table 'x | docs | small | low | * | claude | m1 | 0' "budget '0'" \
  'a zero budget is refused'
bad_table 'x | docs | small | low | * | claude | m1 | 1k' "budget '1k'" \
  'a non-numeric budget is refused'

# A broken rule below the matching one still breaks the table.
printf '%s\n' 'ok | * | * | * | * | claude | m1 | 1' \
  'bad | * | * | * | * | nope | m1 | 1' >"$ROUTES_FILE"
refused "unknown kind 'nope'" 'a broken rule after the match is still refused' route_t docs small low

SHEEPR_ROUTES="$SHEEPR_HOME/missing-routes" refused 'routes file not found' \
  'a missing routes file is refused' route_t docs small low

# --- refusals: the harness must be installed --------------------------------

printf '%s\n' 'c | * | * | * | * | cursor | composer-2.5 | 1' >"$ROUTES_FILE"
rm "$FAKEBIN/cursor-agent"
refused "'cursor-agent' is not installed" 'a missing harness binary is refused, no fallback' \
  route_t docs small low
printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/cursor-agent"; chmod +x "$FAKEBIN/cursor-agent"
is "$(route_t docs small low)" 'cursor composer-2.5 1 c' 'and routes once it is installed'

# --- codex: only through codex-cursor-bridge --------------------------------

printf '%s\n' 'cx | * | * | * | * | codex | composer-2.5 | 1' >"$ROUTES_FILE"

refused 'SHEEPR_CODEX_PROFILE is not set' 'codex without a profile is refused' \
  route_t docs small low

export SHEEPR_CODEX_PROFILE=cursor-bridge
is "$(route_t docs small low)" 'codex composer-2.5 1 cx' \
  'codex with a profile and a catalog model routes'

SHEEPR_CODEX_PROFILE='--sandbox' refused 'SHEEPR_CODEX_PROFILE must match' \
  'codex with an invalid profile is refused' route_t docs small low

printf '%s\n' 'cx | * | * | * | * | codex | claude-opus-5-5 | 1' >"$ROUTES_FILE"
refused 'not in the bridge catalog' 'a codex model missing from the catalog is refused' \
  route_t docs small low

printf '%s\n' 'cx | * | * | * | * | codex | composer-2.5 | 1' >"$ROUTES_FILE"
mv "$CATALOG" "$CATALOG.away"
refused 'bridge catalog is missing' 'codex with no catalog is refused' route_t docs small low
printf 'not json\n' >"$CATALOG"
refused 'not readable' 'an unreadable catalog is refused' route_t docs small low
mv "$CATALOG.away" "$CATALOG"

rm "$FAKEBIN/codex"
refused "'codex' is not installed" 'codex not installed is refused before the catalog' \
  route_t docs small low
unset SHEEPR_CODEX_PROFILE

# --- the shipped table ------------------------------------------------------
#
# The default routes must parse, and its last rule must catch everything.

unset SHEEPR_ROUTES
out=$(route_t feature medium low); rc=$?
is "$rc" '0' 'the shipped routes file parses and routes a plain feature'
last=$(sed 's/#.*//' "$SHEEPR_ROOT/routes" | grep -v '^[[:space:]]*$' | tail -1 \
  | awk -F'|' '{ s = ""; for (i = 2; i <= 5; i++) { f = $i; gsub(/[[:space:]]/, "", f); s = s f } print s }')
is "$last" '****' 'the shipped routes file ends with a catch-all'

finish
