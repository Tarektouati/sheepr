#!/usr/bin/env bash
# bin/sheepr-review.sh - a semantic review of a finished task, by a reviewer.
#
# Usage:
#   sheepr-review.sh start   <task-id> --kind <cursor|claude|codex> \
#                            [--model <id>] [--budget <tokens>] [--route <rule>]
#   sheepr-review.sh collect <task-id>
#   sheepr-review.sh post    <task-id> <n,n,...|all> [--yes]
#
# --kind, --model, --budget and --route usually come from
# `bin/sheepr-route.sh --type review ...`, unless the captain named their own.
#
# Owns: starting the reviewer in a pane split beside the worker (same
# workspace, same worktree; the worker stays alive), the review prompt and its
# sentinel, saving the findings to tasks/<id>/review.md, and posting the
# findings the captain chose to the pull request.
#
# start   splits the worker's pane, starts the reviewer there and prompts
#         `/semantic-review <PR url | branch vs base>`, with an instruction to
#         stop after the findings, post nothing, edit nothing, and end with
#         the sentinel. Records review_pane, review_name, review_kind,
#         review_model, review_budget, review_route, review_target,
#         review_started (also the sentinel's nonce) and, once herdr knows
#         it, review_session in meta, and clears review_done. The watcher then
#         wakes `reviewed: <id>` when the sentinel appears.
#
#         A claude reviewer runs under --permission-mode plan, so the harness
#         itself holds it read-only. cursor and codex reviewers run with their
#         normal worker permissions; only the prompt forbids edits.
#
# collect reads the reviewer pane through the Herdr adapter, writes what lies
#         between the BEGIN marker and the sentinel to tasks/<id>/review.md,
#         closes the reviewer pane and records review_done. Its findings
#         travel with the task: teardown archives review.md with the rest.
#
# post    (pr delivery only) builds one GitHub review from the chosen
#         findings: inline comments for the ones that anchor to a line of the
#         PR's diff, the rest moved into the body under the verdict, and the
#         event (REQUEST_CHANGES for any Crucial or Important, COMMENT on your
#         own PR or when a Question is chosen, APPROVE otherwise). A finding
#         that duplicates one of your existing comments (same path, line,
#         side and label, and text that matches once case and punctuation are
#         set aside, or one that starts with the other's first 60 characters)
#         is skipped and listed. Without --yes it prints the exact review and
#         posts nothing. With --yes it posts it with `gh` and prints the
#         review URL. When GitHub refuses an APPROVE, the same review is sent
#         as COMMENT with the refusal and LGTM in the body.
#
# Refuses:
#   start   - unless the task's fold is `done`: a review is of finished work.
#           - while a review is already open on the task.
#           - without --kind, or with a kind, model, budget or route that
#             spawn would refuse.
#           - pr delivery with no pull request URL in the done line or in
#             flock's row; branch or local delivery with no `base` in meta
#             (a task spawned before spawn recorded it). A guessed target
#             reviews the wrong diff.
#           - when the reviewer cannot be started or prompted. The new pane
#             is closed again and nothing is recorded.
#   collect - unless a review is open.
#           - when the reviewer pane cannot be read, or holds no sentinel:
#             the reviewer is not finished, and half a review is not one.
#           - when the BEGIN marker is not in the pane, since the findings
#             cannot then be told from the prompt and the scrollback.
#           - when the pane cannot be closed. review.md is kept, the review
#             stays open, and collect can be run again.
#   post    - unless delivery is `pr`, the review was collected, and every
#             number given is a finding in review.md.
#           - when gh cannot read the PR, its diff or your existing comments.
#             Unread duplicates would be posted twice.
#           - to post anything without --yes.
#
# The reviewer never posts, and never addresses the captain: everything it
# says reaches the captain through the supervisor (hard rule 4).
#
# Verified with claude 2.1.325 under herdr 0.9.5 (see bin/sheepr-herdr.sh).
# The cursor and codex reviewer paths use launch args already verified for
# workers; whether their harness runs the /semantic-review skill from that
# prompt was not checked.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"
# shellcheck source=bin/sheepr-flock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-flock.sh"

# How much scrollback collect reads. A review is far shorter; the margin is
# for a reviewer that read many files on the way.
SHEEPR_REVIEW_READ_LINES=${SHEEPR_REVIEW_READ_LINES:-5000}

usage() {
  sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# --- the prompt ---------------------------------------------------------------

# The sentinel is described in parts, never written whole, so the prompt's
# echo in the pane is never mistaken for it.
review_prompt() {  # <target> <nonce>
  printf '/semantic-review %s. ' "$1"
  printf 'This review is for a supervisor, not the author. Stop after printing the findings (step 4): '
  printf 'do not post anything, do not ask which comments to post, do not ask any question, '
  printf 'do not edit, create or delete any file, and do not call ExitPlanMode. '
  printf 'Before the target line, print one line that is exactly the word SHEEPR-REVIEW-BEGIN '
  printf 'followed by a hyphen and the number %s, with no space. ' "$2"
  printf 'After the last finding, print one last line that is exactly the word SHEEPR-REVIEW-DONE '
  printf 'followed by a hyphen and the number %s, with no space, and nothing after it.' "$2"
}

# --- start ----------------------------------------------------------------------

cmd_start() {
  local id=$1; shift
  local kind='' model='' budget='' route=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) [ $# -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --model) [ $# -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
      --budget) [ $# -ge 2 ] || die "--budget needs a value"; budget=$2; shift 2 ;;
      --route) [ $# -ge 2 ] || die "--route needs a value"; route=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [ -n "$kind" ] || die "--kind is required (one of: $SHEEPR_AGENT_KINDS); route it with sheepr-route.sh --type review"
  sheepr_kind_valid "$kind" || die "unknown --kind '$kind' (one of: $SHEEPR_AGENT_KINDS)"
  if [ -n "$model" ]; then
    sheepr_model_valid "$model" || die "--model '$model' must match $SHEEPR_MODEL_RE"
  fi
  if [ -n "$budget" ]; then
    [[ $budget =~ ^[1-9][0-9]*$ ]] || die "--budget '$budget' must be a positive integer (tokens)"
  fi
  if [ -n "$route" ]; then
    [[ $route =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "--route '$route' is not a rule name"
  fi

  local fold state
  fold=$(sheepr_status_fold "$id"); state=${fold%%|*}
  [ "$state" = done ] || die "refusing to review $id: its fold is '$state', not done"
  sheepr_review_open "$id" && die "refusing to review $id: a review is already open (sheepr-review.sh collect $id)"

  local delivery worktree branch base pane target
  delivery=$(sheepr_meta_get "$id" delivery) || die "task $id has no recorded delivery mode"
  worktree=$(sheepr_meta_get "$id" worktree) || die "task $id has no recorded worktree"
  [ -d "$worktree" ] || die "the worktree is gone: $worktree"
  branch=$(sheepr_meta_get "$id" branch) || die "task $id has no recorded branch"

  case "$delivery" in
    pr)
      target=$(printf '%s' "${fold#*|*|}" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | head -1)
      if [ -z "$target" ]; then
        local repo json row
        repo=$(sheepr_meta_get "$id" repo) || repo=''
        if [ -n "$repo" ] && sheepr_flock_dir >/dev/null && json=$(sheepr_flock_status "$repo") \
             && row=$(sheepr_flock_row "$json" "$worktree"); then
          target=$(printf '%s' "$row" | jq -r '.pr.url // empty')
        fi
      fi
      [ -n "$target" ] || die "refusing to review $id: delivery is pr but no pull request URL is in its done line or in flock"
      ;;
    branch|local)
      base=$(sheepr_meta_get "$id" base) || base=''
      [ -n "$base" ] || die "refusing to review $id: meta records no base (spawned before spawn recorded one); give the task a base= line in meta first"
      target="$branch vs $base (the base is settled: do not ask for it)"
      ;;
    *) die "task $id has an unknown delivery mode '$delivery'" ;;
  esac

  sheepr_herdr_require

  local wpane name nonce new rc
  wpane=$(sheepr_meta_get "$id" pane) || die "task $id has no recorded pane"
  name="rv-$id"
  nonce=$(sheepr_now)

  new=$(sheepr_pane_split "$wpane" "$worktree") || die "could not split a reviewer pane beside $wpane"

  if ! sheepr_reviewer_start "$name" "$kind" "$new" "$model"; then
    sheepr_pane_close "$new" || warn "the failed reviewer pane $new could not be closed"
    die "the reviewer did not become ready; nothing was recorded"
  fi

  sheepr_agent_prompt_verified "$name" "$(review_prompt "$target" "$nonce")" ''
  rc=$?
  case "$rc" in
    0|4) ;;
    *)
      sheepr_pane_close "$new" || warn "the failed reviewer pane $new could not be closed"
      die "could not prompt the reviewer; its pane was closed and nothing was recorded"
      ;;
  esac

  local dir
  dir=$(sheepr_task_dir "$id")
  rm -f "$dir/.review-budget-woke" "$dir/.review-quiet-since" "$dir/.review-seen" \
        "$dir/.review-usage-unknown-since"
  sheepr_meta_set "$id" review_pane "$new"
  sheepr_meta_set "$id" review_name "$name"
  sheepr_meta_set "$id" review_kind "$kind"
  sheepr_meta_set "$id" review_model "$model"
  sheepr_meta_set "$id" review_budget "$budget"
  sheepr_meta_set "$id" review_route "$route"
  sheepr_meta_set "$id" review_target "$target"
  sheepr_meta_set "$id" review_session ''
  sheepr_meta_set "$id" review_done ''
  sheepr_meta_set "$id" review_started "$nonce"
  sheepr_review_record_session "$id" "$name" 10 || true

  printf 'review started for %s\n' "$id"
  printf '  reviewer  %s %s\n' "$kind" "${model:-harness default}"
  printf '  budget    %s\n' "${budget:-none}"
  printf '  target    %s\n' "$target"
  printf '  pane      %s (beside %s)\n' "$new" "$wpane"
  [ "$rc" = 0 ] || warn "the prompt was submitted but no turn was observed yet; the watcher will report a stall"
}

# --- collect --------------------------------------------------------------------

# Strip a harness's bullet from the first findings line and the indent the
# harness put on every line, and drop leading and trailing blank lines.
clean_findings() {
  awk '
    { line[NR] = $0 }
    END {
      # The first line carries the bullet the harness put on its reply.
      sub(/^[[:space:]]*(⏺|•|●)[[:space:]]/, "  ", line[1])
      min = -1
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^[[:space:]]*$/) continue
        match(line[i], /^ */)
        if (min < 0 || RLENGTH < min) min = RLENGTH
      }
      if (min < 0) min = 0
      first = 0; last = 0
      for (i = 1; i <= NR; i++) if (line[i] !~ /^[[:space:]]*$/) { if (!first) first = i; last = i }
      for (i = first; i && i <= last; i++) {
        l = line[i]; sub(/[[:space:]]+$/, "", l)
        print substr(l, min + 1)
      }
    }'
}

cmd_collect() {
  local id=$1
  [ $# -eq 1 ] || die "usage: sheepr-review.sh collect <task-id>"
  sheepr_review_open "$id" || die "no review is open on $id"
  sheepr_herdr_require

  local pane nonce text done_at begin_at out dir
  pane=$(sheepr_meta_get "$id" review_pane) || die "task $id records no reviewer pane"
  nonce=$(sheepr_meta_get "$id" review_started) || die "task $id records no review start"
  text=$(sheepr_pane_read "$pane" "$SHEEPR_REVIEW_READ_LINES") \
    || die "refusing to collect $id: the reviewer pane $pane cannot be read"
  done_at=$(sheepr_marker_line "$text" "$(sheepr_review_marker DONE "$nonce")") \
    || die "refusing to collect $id: no sentinel in the reviewer pane yet; the review is not finished"
  begin_at=$(sheepr_marker_line "$(printf '%s\n' "$text" | head -n "$done_at")" \
               "$(sheepr_review_marker BEGIN "$nonce")") \
    || die "refusing to collect $id: the BEGIN marker is not in the pane, so the findings cannot be told apart"

  dir=$(sheepr_task_dir "$id")
  out="$dir/review.md"
  {
    printf '<!-- sheepr review: task=%s target=%s kind=%s model=%s started=%s collected=%s -->\n' \
      "$id" "$(sheepr_meta_get "$id" review_target)" "$(sheepr_meta_get "$id" review_kind)" \
      "$(sheepr_meta_get "$id" review_model)" "$nonce" "$(sheepr_now)"
    printf '%s\n' "$text" | sed -n "$((begin_at + 1)),$((done_at - 1))p" | clean_findings
  } >"$out.tmp" && mv -f "$out.tmp" "$out" || die "could not write $out"

  sheepr_pane_close "$pane" \
    || die "saved $out, but the reviewer pane $pane could not be closed; the review stays open, run collect again"
  sheepr_meta_set "$id" review_done "$(sheepr_now)"

  printf 'review collected for %s: %s finding(s) in %s\n' "$id" "$(parse_findings "$out" | jq 'length')" "$out"
}

# --- post -----------------------------------------------------------------------

# review.md's numbered findings as a JSON array of
# {n, path, line, start_line, side, label, text}. side is LEFT for a
# `path:-line` (a removed line) and RIGHT otherwise. Rendered and raw markdown
# both parse: `**Label:**` or `Label:`, a location with or without backticks.
parse_findings() {  # <review.md>
  awk '
    function flush() {
      if (n != "") printf "%s\t%s\t%s\n", n, loc, body
      n = ""; loc = ""; body = ""
    }
    /^<!-- sheepr review:/ { next }
    match($0, /^[[:space:]]*[0-9]+\.[[:space:]]+/) {
      flush()
      head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      gsub(/[^0-9]/, "", head); n = head
      loc = rest; sub(/[[:space:]].*$/, "", loc)
      rest = substr(rest, length(loc) + 1)
      gsub(/`/, "", loc)
      sub(/^[[:space:]]*/, "", rest)
      body = rest
      next
    }
    # A finding ends at the first blank line: what follows is a severity
    # heading, the next finding, or the closing prose of the reviewer.
    /^[[:space:]]*$/ { flush(); next }
    n != "" { t = $0; sub(/^[[:space:]]+/, "", t); body = (body == "" ? t : body " " t) }
    END { flush() }
  ' "$1" | jq -R -s -c '
    [ split("\n")[] | select(length > 0) | split("\t")
      | {n: (.[0] | tonumber), loc: .[1], body: .[2]}
      | (.loc | capture("^(?<path>[^:]+):(?<neg>-?)(?<a>[0-9]+)(-(?<b>[0-9]+))?$")?) as $l
      | (.body | capture("^\\**(?<label>Crucial|Important|Question|Suggestion|Hint|Remark):\\**\\s*(?<text>.*)$")?) as $b
      | select($l != null and $b != null)
      | {n, path: $l.path,
         side: (if $l.neg == "-" then "LEFT" else "RIGHT" end),
         line: (($l.b // $l.a) | tonumber),
         start_line: (if $l.b then ($l.a | tonumber) else null end),
         label: $b.label, text: $b.text} ]'
}

# The lines a review comment can anchor to, from a unified diff, one
# "<path>\t<RIGHT|LEFT>\t<line>" per line.
anchorable_lines() {
  awk '
    /^diff --git / { path = ""; oldp = ""; next }
    /^--- / { oldp = substr($0, 5); sub(/^a\//, "", oldp); next }
    /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); if (path == "/dev/null") path = oldp; next }
    /^@@ / {
      split($2, o, ","); split($3, w, ",")
      ol = substr(o[1], 2) + 0; nl = substr(w[1], 2) + 0
      inhunk = 1; next
    }
    !inhunk || path == "" { next }
    /^\+/ { printf "%s\tRIGHT\t%d\n", path, nl; nl++; next }
    /^-/  { printf "%s\tLEFT\t%d\n", path, ol; ol++; next }
    /^ / || /^$/ { printf "%s\tRIGHT\t%d\n", path, nl; ol++; nl++; next }
  '
}

cmd_post() {
  local id=$1; shift
  local sel='' yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;;
      -*) die "unknown argument: $1" ;;
      *) [ -z "$sel" ] || die "unexpected argument: $1"; sel=$1 ;;
    esac
    shift
  done
  [ -n "$sel" ] || die "usage: sheepr-review.sh post <task-id> <n,n,...|all> [--yes]"

  local delivery url file findings chosen
  delivery=$(sheepr_meta_get "$id" delivery) || die "task $id has no recorded delivery mode"
  [ "$delivery" = pr ] || die "refusing to post for $id: delivery is '$delivery', and only a pull request takes a review"
  file="$(sheepr_task_dir "$id")/review.md"
  [ -f "$file" ] && ! sheepr_review_open "$id" \
    || die "refusing to post for $id: no collected review (sheepr-review.sh collect $id)"
  url=$(sheepr_meta_get "$id" review_target) || url=''
  [[ $url =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]] \
    || die "refusing to post for $id: '$url' is not a GitHub pull request URL"
  local owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} num=${BASH_REMATCH[3]}

  findings=$(parse_findings "$file") || die "could not parse $file"
  [ "$(printf '%s' "$findings" | jq 'length')" -gt 0 ] || die "refusing to post for $id: $file holds no findings"

  if [ "$sel" = all ]; then
    chosen=$findings
  else
    [[ $sel =~ ^[0-9]+(,[0-9]+)*$ ]] || die "'$sel' is not a list of finding numbers like 1,3,5"
    local missing
    missing=$(printf '%s' "$findings" | jq -r --arg s "$sel" \
      '($s | split(",") | map(tonumber)) - map(.n) | map(tostring) | join(",")')
    [ -z "$missing" ] || die "refusing to post for $id: no finding numbered $missing in $file"
    chosen=$(printf '%s' "$findings" | jq -c --arg s "$sel" \
      '($s | split(",") | map(tonumber)) as $want | map(select(.n as $n | $want | index($n)))')
  fi

  sheepr_require_tools gh jq
  local R="$owner/$repo" pr me diff anchors existing bodies
  pr=$(gh pr view "$num" -R "$R" --json headRefOid,author 2>/dev/null) \
    || die "gh could not read $url"
  me=$(gh api user -q .login 2>/dev/null) || die "gh could not tell who you are"
  diff=$(gh pr diff "$num" -R "$R" 2>/dev/null) || die "gh could not read the diff of $url"
  anchors=$(printf '%s\n' "$diff" | anchorable_lines | jq -R -s -c \
    '[split("\n")[] | select(length > 0) | split("\t") | {path: .[0], side: .[1], line: (.[2] | tonumber)}]')
  existing=$(gh api "repos/$R/pulls/$num/comments" --paginate \
    --jq "[.[] | select(.user.login == \"$me\") | {path, side, line: (.line // .original_line), body}]" 2>/dev/null) \
    || die "gh could not read your existing comments on $url"
  bodies=$(gh api "repos/$R/pulls/$num/reviews" --paginate \
    --jq "[.[] | select(.user.login == \"$me\") | .body]" 2>/dev/null) \
    || die "gh could not read your existing reviews on $url"
  # --paginate prints one array per page.
  existing=$(printf '%s\n' "$existing" | jq -s -c 'add // []')
  bodies=$(printf '%s\n' "$bodies" | jq -s -c 'add // []')

  local plan
  plan=$(jq -n -c \
    --argjson chosen "$chosen" --argjson anchors "$anchors" \
    --argjson existing "$existing" --argjson bodies "$bodies" \
    --arg head "$(printf '%s' "$pr" | jq -r .headRefOid)" \
    --arg own "$([ "$(printf '%s' "$pr" | jq -r .author.login)" = "$me" ] && echo 1 || echo 0)" '
    def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
    def similar($a; $b): ($a | norm) as $x | ($b | norm) as $y
      | $x == $y or ($x | startswith($y[:60])) or ($y | startswith($x[:60]));
    def loc: "\(.path):\(if .side == "LEFT" then "-" else "" end)\(if .start_line then "\(.start_line)-" else "" end)\(.line)";
    def bodyline: "- `\(loc)` **\(.label):** \(.text)";
    def at($c; $l): any($anchors[]; .path == $c.path and .side == $c.side and .line == $l);
    def anchored($c): at($c; $c.line) and ($c.start_line == null or at($c; $c.start_line));
    def dup($c):
      any($existing[]; .path == $c.path and .side == $c.side and .line == $c.line
          and (.body | startswith("**\($c.label):**"))
          and similar(.body | sub("^\\*\\*[A-Za-z]+:\\*\\*\\s*"; ""); $c.text))
      or any($bodies[] | select(. != null) | split("\n")[];
          startswith("- `\($c | loc)` **\($c.label):**")
          and similar(sub("^- `[^`]*` \\*\\*[A-Za-z]+:\\*\\*\\s*"; ""); $c.text));
    ($chosen | map(select(dup(.)))) as $skipped
    | ($chosen | map(select(dup(.) | not))) as $post
    | ($post | map(select(anchored(.)))) as $inline
    | ($post | map(select(anchored(.) | not))) as $moved
    | ($post | map(select(.label == "Crucial")) | length) as $crucial
    | ($post | map(select(.label == "Important")) | length) as $important
    | ($post | map(select(.label == "Question")) | length) as $questions
    | (if $crucial > 0 then "Blocks merge (\($crucial) Crucial)"
       elif $important > 0 then "Changes expected (\($important) Important)"
       else "OK to merge" end) as $verdict
    | (if $crucial + $important > 0 then (if $own == "1" then "COMMENT" else "REQUEST_CHANGES" end)
       elif $questions > 0 then "COMMENT" else "APPROVE" end) as $event
    | {skipped: $skipped, moved: $moved,
       review: {commit_id: $head, event: $event,
                body: ([$verdict] + (if ($moved | length) > 0 then [""] + ($moved | map(bodyline)) else [] end) | join("\n")),
                comments: ($inline | map({path, line, side, body: "**\(.label):** \(.text)"}
                  + (if .start_line then {start_line, start_side: .side} else {} end)))}}') \
    || die "could not build the review"

  printf 'Review for %s (%s), event %s\n\n' "$url" "$id" "$(printf '%s' "$plan" | jq -r .review.event)"
  printf 'Inline comments:\n'
  printf '%s' "$plan" | jq -r '.review.comments | if length == 0 then "  (none)" else
    .[] | "  \(.path):\(if .side == "LEFT" then "-" else "" end)\(.line)  \(.body)" end'
  printf '\nBody:\n'
  printf '%s' "$plan" | jq -r '.review.body' | sed 's/^/  /'
  if [ "$(printf '%s' "$plan" | jq '.moved | length')" -gt 0 ]; then
    printf '\nMoved into the body (no anchor in the diff): %s\n' "$(printf '%s' "$plan" | jq -r '.moved | map(.n) | join(", ")')"
  fi
  if [ "$(printf '%s' "$plan" | jq '.skipped | length')" -gt 0 ]; then
    printf '\nSkipped as duplicates of your existing comments: %s\n' "$(printf '%s' "$plan" | jq -r '.skipped | map(.n) | join(", ")')"
  fi

  if [ "$yes" = 0 ]; then
    printf '\nNothing was posted. Run again with --yes to post exactly this.\n'
    return 0
  fi

  if [ "$(printf '%s' "$plan" | jq '(.review.comments | length) + (.moved | length)')" = 0 ] \
     && [ "$(printf '%s' "$plan" | jq '.skipped | length')" -gt 0 ]; then
    printf '\nEvery chosen finding is already posted; nothing to send.\n'
    return 0
  fi

  local payload resp out
  payload=$(mktemp "${TMPDIR:-/tmp}/sheepr-review-XXXXXX") || die "could not write the review payload"
  printf '%s' "$plan" | jq '.review' >"$payload"
  if ! resp=$(gh api "repos/$R/pulls/$num/reviews" -X POST --input "$payload" 2>&1); then
    if [ "$(jq -r .event "$payload")" = APPROVE ]; then
      local why
      why=$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null)
      [ -n "$why" ] || why=$(printf '%s' "$resp" | head -1)
      jq --arg w "$why" '.event = "COMMENT"
        | .body = ((.body | split("\n")) as $l
                   | ([$l[0], "", "Approval was not possible (\($w)). LGTM: no blocking issues found."] + $l[1:])
                   | join("\n"))' "$payload" >"$payload.c" && mv -f "$payload.c" "$payload"
      if ! resp=$(gh api "repos/$R/pulls/$num/reviews" -X POST --input "$payload" 2>&1); then
        rm -f "$payload"
        die "GitHub refused the approval ($why) and then the comment fallback; nothing was posted: $(printf '%s' "$resp" | head -3)"
      fi
      warn "GitHub refused the approval ($why); posted as COMMENT with LGTM in the body"
    else
      rm -f "$payload"
      die "GitHub refused the review; nothing was posted: $(printf '%s' "$resp" | head -3)"
    fi
  fi
  rm -f "$payload"
  out=$(printf '%s' "$resp" | jq -r '.html_url // empty' 2>/dev/null)
  sheepr_meta_set "$id" review_posted "$(sheepr_now)"
  printf '\nposted: %s\n' "${out:-review posted, but GitHub returned no URL}"
}

# --- main -----------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -ge 2 ] || usage
  CMD=$1; ID=$2; shift 2
  sheepr_validate_id "$ID"
  sheepr_task_exists "$ID" || die "no such task: $ID"
  sheepr_require_tools jq
  case "$CMD" in
    start) cmd_start "$ID" "$@" ;;
    collect) cmd_collect "$ID" "$@" ;;
    post) cmd_post "$ID" "$@" ;;
    *) usage ;;
  esac
fi
