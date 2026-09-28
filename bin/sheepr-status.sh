#!/usr/bin/env bash
# bin/sheepr-status.sh - the status log: append, and fold to current state.
#
# Usage:
#   sheepr-status.sh fold   <task-id>            -> <state>|<key>|<text>
#   sheepr-status.sh open   <task-id>            -> one open key per line
#   sheepr-status.sh append <task-id> <verb> <key> <text>
#
# Owns: the status line grammar and the fold that turns an append-only log
# into a single current state.
#
# Refuses: to decide anything from the last line alone. A question written ten
# lines ago is still open, and reading only the tail buries it under later
# progress. That property is the whole reason this file exists.
#
# Grammar, four pipe-separated fields:
#
#     <verb>|<unix-epoch>|<key>|<text>
#
# Verbs a worker may write:
#   working   progress, no action needed
#   question  needs a captain decision; carries a key; the worker stops
#   blocked   needs the supervisor; carries an optional key; the worker stops
#   done      finished, with delivery evidence in the text
#   failed    gave up, with the reason in the text
#
# Verb only the supervisor writes:
#   resolved  closes the question or blocker with the matching key
#
# An unrecognised line is ignored rather than fatal: workers occasionally write
# prose into the log, and losing the fold over that would be worse than
# skipping it.

set -uo pipefail

# shellcheck source=bin/sheepr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-lib.sh"

SHEEPR_DEFAULT_KEY='default'

# The fold, as one awk pass.
#
# Open entries are kept in insertion order so "oldest open" is well defined.
# A repeated key updates the existing entry in place and keeps its original
# position, because re-asking the same question is the same question.
_sheepr_fold_awk() {
  awk -F'|' -v dflt="$SHEEPR_DEFAULT_KEY" '
    {
      verb = $1
      key  = ($3 == "" ? dflt : $3)
      text = $4
      # A text field containing pipes is rejoined so nothing is lost.
      for (i = 5; i <= NF; i++) text = text "|" $i

      if (verb == "done" || verb == "failed") {
        term_verb = verb; term_text = text; seen = 1
      } else if (verb == "question" || verb == "blocked") {
        if (!known[key]) { order[++n] = key; known[key] = 1 }
        live[key] = 1; kind[key] = verb; msg[key] = text; seen = 1
      } else if (verb == "resolved") {
        live[key] = 0; seen = 1
      } else if (verb == "working") {
        seen = 1
      }
      # anything else: ignored, deliberately
    }
    END {
      if (term_verb != "") { printf "%s||%s\n", term_verb, term_text; exit }
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (live[k]) { printf "%s|%s|%s\n", kind[k], k, msg[k]; exit }
      }
      if (seen) printf "working||\n"; else printf "empty||\n"
    }
  '
}

sheepr_status_fold() {  # <task-id> -> <state>|<key>|<text>
  local f
  f=$(sheepr_status_file "$1")
  if [ ! -f "$f" ]; then printf 'empty||\n'; return 0; fi
  _sheepr_fold_awk <"$f"
}

sheepr_status_open_keys() {  # <task-id> -> one open key per line
  local f
  f=$(sheepr_status_file "$1")
  [ -f "$f" ] || return 0
  awk -F'|' -v dflt="$SHEEPR_DEFAULT_KEY" '
    { key = ($3 == "" ? dflt : $3) }
    $1 == "question" || $1 == "blocked" { if (!live[key]) { order[++n] = key }; live[key] = 1 }
    $1 == "resolved" { live[key] = 0 }
    END { for (i = 1; i <= n; i++) if (live[order[i]]) print order[i] }
  ' <"$f"
}

sheepr_status_append() {  # <task-id> <verb> <key> <text>
  local id=$1 verb=$2 key=$3 text=$4 f
  f=$(sheepr_status_file "$id")
  mkdir -p "$(dirname "$f")"
  # Strip pipes and newlines so a written line can never desync the four-field
  # shape the fold depends on.
  key=$(printf '%s' "$key" | tr -d '|\n')
  text=$(printf '%s' "$text" | tr '|\n' '  ')
  printf '%s|%s|%s|%s\n' "$verb" "$(sheepr_now)" "$key" "$text" >>"$f"
}

# --- cli --------------------------------------------------------------------

# Only run the dispatcher when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd=${1:-}; shift || true
  case "$cmd" in
    fold)
      [ $# -ge 1 ] || die "usage: sheepr-status.sh fold <task-id>"
      sheepr_status_fold "$1"
      ;;
    open)
      [ $# -ge 1 ] || die "usage: sheepr-status.sh open <task-id>"
      sheepr_status_open_keys "$1"
      ;;
    append)
      [ $# -ge 3 ] || die "usage: sheepr-status.sh append <task-id> <verb> <key> <text>"
      sheepr_status_append "$1" "$2" "${3:-}" "${4:-}"
      ;;
    *)
      die "usage: sheepr-status.sh fold|open|append <task-id> ..."
      ;;
  esac
fi
