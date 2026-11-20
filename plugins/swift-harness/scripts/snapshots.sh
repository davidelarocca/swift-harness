#!/bin/bash
# Approve new snapshot images as baselines (#9). Run by the user through
# /swift-harness:approve-snapshots, never by a hook.
#
#   snapshots.sh --status [--project DIR]                    list the images waiting, and a digest
#   snapshots.sh --approve DIGEST [--project DIR] [NAME...]  copy them into the baselines folder,
#                                                            only if DIGEST is still current
#   snapshots.sh --relative-paths [--project DIR]            in the metadata of the baselines,
#                                                            make an absolute test path relative
#
# The project's tests (templates/tests/Snapshot.swift) never write a baseline: a missing or
# different image leaves <name>.png, .json, .diff.png and .result.json in
# .build/swift-harness/snapshots/. Approving copies the image and its metadata into
# `snapshots.path` (default snapshots/) and records it, so the end-of-turn notice
# (snapshot-watch.sh) does not report it as changed without approval.
#
# --status also writes a page for the user to look at, review.html in the same folder as the new
# images, and prints its path: every image waiting with its approved one and the changed pixels
# side by side, the largest changes first. An approval is given on what the user saw there, not
# on a description. A static file: no script, nothing from outside the project.
#
# The metadata names the test file relative to the project. A Snapshot.swift older than 1.12.0
# wrote its absolute path, with the account name and the folders of the Mac that ran the test:
# an approval makes it relative, and --relative-paths does the same for the baselines already
# approved. Only that field changes; no check reads it.

usage() {
  echo "usage: snapshots.sh --status [--project DIR] | --approve DIGEST [--project DIR] [NAME...] | --relative-paths [--project DIR]" >&2
  exit 2
}

action="${1:-}"
digest=""
case "$action" in
  --status | --relative-paths) shift ;;
  --approve)
    digest="${2:-}"
    [ -n "$digest" ] || usage
    shift 2
    ;;
  *) usage ;;
esac
dir="$PWD"
if [ "${1:-}" = "--project" ]; then
  [ -n "${2:-}" ] || usage
  dir="$2"
  shift 2
fi
[ "$action" != "--approve" ] && [ $# -gt 0 ] && usage

if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
  echo "swift-harness: CLAUDE_PLUGIN_DATA is not set. Run this through /swift-harness:approve-snapshots." >&2
  exit 1
fi

. "$(dirname "$0")/lib.sh" </dev/null
SH_INPUT="$(jq -nc --arg cwd "$dir" '{cwd: $cwd}' 2>/dev/null)"
if ! sh_init; then
  echo "swift-harness: no .claude/swift-harness.json in $dir (or jq is missing)." >&2
  exit 1
fi
state="$(sh_state_dir)" || {
  echo "swift-harness: cannot create the state folder under $CLAUDE_PLUGIN_DATA." >&2
  exit 1
}

baselines="$(sh_snapshots)"
case "/$baselines/" in
  //* | */../* | *//*)
    echo "swift-harness: snapshots.path '$baselines' must be a folder inside the project, without '..'." >&2
    exit 1
    ;;
esac
candidates="$SH_ROOT/$SH_SNAPSHOT_CANDIDATES"

sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# A test file for the metadata: $1 as it is when relative. An absolute path under the project
# loses the root; one from another folder or another Mac keeps its longest tail that is a file
# here, else its name alone.
relative_test() {
  local p="$1" real tail
  case "$p" in /*) ;; *) printf '%s' "$p"; return 0 ;; esac
  real="$(cd "$SH_ROOT" 2>/dev/null && pwd -P)"
  case "$p" in
    "$SH_ROOT"/*) printf '%s' "${p#"$SH_ROOT"/}"; return 0 ;;
    "${real:-$SH_ROOT}"/*) printf '%s' "${p#"$real"/}"; return 0 ;;
  esac
  tail="${p#/}"
  while [[ "$tail" == */* ]]; do
    tail="${tail#*/}"
    [ -f "$SH_ROOT/$tail" ] && { printf '%s' "$tail"; return 0; }
  done
  printf '%s' "${p##*/}"
}
# The metadata in file $1 with a relative test path, on stdout. $2 and $3: the time and the
# status of an approval, to add.
relative_meta() {
  local test
  test="$(relative_test "$(jq -r 'if (.test | type) == "string" then .test else "" end' "$1" 2>/dev/null)")"
  jq --arg test "$test" --arg now "${2:-}" --arg status "${3:-}" '
    (if $now != "" then . + {approved: $now, approvedFrom: $status} else . end)
    | if (.test | type) == "string" then .test = $test else . end' "$1"
}

if [ "$action" = "--relative-paths" ]; then
  absolute="$(sh_snapshot_absolute "$baselines")"
  if [ -z "$absolute" ]; then
    echo "No baseline metadata in $baselines/ holds an absolute path. Nothing changed."
    exit 0
  fi
  count=0
  while IFS= read -r rel; do
    json="$SH_ROOT/$rel"
    if ! relative_meta "$json" >"$json.tmp" || ! mv "$json.tmp" "$json"; then
      rm -f "$json.tmp"
      echo "swift-harness: cannot write $json. Stopped after the files listed above." >&2
      exit 1
    fi
    # Recorded as approved for every open session: the end-of-turn notice stays quiet.
    printf '%s %s\n' "$(sha "$json")" "$rel" | sh_sessions_append "$state" snapshots-approved snapshots-start
    printf 'Made relative: %s (test: %s)\n' "$rel" "$(jq -r .test "$json")"
    count=$((count + 1))
  done <<<"$absolute"
  sh_catch "snapshot baselines" approved "$count metadata file(s): absolute test path made relative"
  echo "Commit $baselines/: only the \"test\" field of $count metadata file(s) changed, the images are the same. A commit already made keeps the old path in the history."
  exit 0
fi

# Images waiting: one line "<name>\t<status>\t<reason>" for each result that is not a match
# and still has its new image.
pending() {
  local result name
  [ -d "$candidates" ] || return 0
  for result in "$candidates"/*.result.json; do
    [ -f "$result" ] || continue
    name="$(basename "$result" .result.json)"
    [ -f "$candidates/$name.png" ] || continue
    jq -r --arg name "$name" 'select(.status != "passed") | [$name, .status, (.reason // "")] | @tsv' "$result" 2>/dev/null
  done
}

# What is approved: every image, its metadata and status. Changes when a test runs again.
current_digest() {
  local name status
  while IFS=$'\t' read -r name status _; do
    printf '%s %s %s %s\n' "$name" "$status" "$(sha "$candidates/$name.png")" "$(sha "$candidates/$name.json")"
  done < <(pending) | shasum -a 256 | cut -d' ' -f1
}

list="$(pending)"

# The review page. Prints its path, or nothing when it could not be written (a link in the way,
# an unwritable folder): the status then goes on without it.
review_page() {
  local page="$candidates/review.html" tmp name status reason items path
  # The scripts change no file outside the project, and a link could lead there.
  for path in "$SH_ROOT/.build" "$SH_ROOT/.build/swift-harness" "$candidates" "$page"; do
    [ ! -L "$path" ] || return 0
  done
  items="$(
    while IFS=$'\t' read -r name status reason; do
      [ -n "$name" ] || continue
      jq -nc --arg name "$name" --arg status "$status" --arg reason "$reason" \
        --slurpfile meta <(jq -c 'if type == "object" then . else {} end' "$candidates/$name.json" 2>/dev/null || echo '{}') \
        --slurpfile baseline <(jq -c 'if type == "object" then {os, scale} else {} end' "$SH_ROOT/$baselines/$name.json" 2>/dev/null || echo '{}') \
        --argjson diff "$([ -f "$candidates/$name.diff.png" ] && echo true || echo false)" \
        --argjson old "$([ -f "$SH_ROOT/$baselines/$name.png" ] && echo true || echo false)" \
        '{name: $name, status: $status, reason: $reason, meta: ($meta[0] // {}), baseline: ($baseline[0] // {}), diff: $diff, old: $old}'
    done <<<"$list" | jq -sc .
  )"
  [ -n "$items" ] || return 0
  # A temp file renamed over the page: a redirection would write through a hard link.
  tmp="$candidates/.review.$$.html"
  if jq -nr --argjson items "$items" --arg project "$(basename "$SH_ROOT")" --arg baselines "$baselines" --arg up "../../../" \
    --arg made "$(date -u +%Y-%m-%dT%H:%M:%SZ)" -f "$(dirname "$0")/snapshots-page.jq" >"$tmp" 2>/dev/null && mv -f "$tmp" "$page"; then
    printf '%s' "$page"
  else
    rm -f "$tmp"
  fi
}

if [ "$action" = "--status" ]; then
  printf 'Project: %s\nBaselines: %s/\n' "$SH_ROOT" "$baselines"
  absolute="$(sh_snapshot_absolute "$baselines" | grep -c .)"
  [ "$absolute" -eq 0 ] || printf '%s metadata file(s) in %s/ hold the absolute path of the test file on the Mac that made them (an older Snapshot.swift wrote it). Make them relative: snapshots.sh --relative-paths\n' "$absolute" "$baselines"
  if [ -z "$list" ]; then
    echo "No new images wait for approval. Run the snapshot tests first: a missing or different image leaves one in $SH_SNAPSHOT_CANDIDATES/."
    exit 0
  fi
  while IFS=$'\t' read -r name status reason; do
    printf '\n%s: %s\n' "$name" "$status"
    [ -n "$reason" ] && printf '  %s\n' "$reason"
    printf '  New image: %s\n' "$candidates/$name.png"
    [ -f "$candidates/$name.diff.png" ] && printf '  Changes in red: %s\n' "$candidates/$name.diff.png"
    if [ -f "$SH_ROOT/$baselines/$name.png" ]; then
      printf '  Baseline: %s (made on macOS %s)\n' "$SH_ROOT/$baselines/$name.png" "$(jq -r '.os // "?"' "$SH_ROOT/$baselines/$name.json" 2>/dev/null || echo '?')"
    fi
    printf '  New image made on macOS %s at scale %s\n' "$(jq -r '.os // "?"' "$candidates/$name.json" 2>/dev/null)" "$(jq -r '.scale // "?"' "$candidates/$name.json" 2>/dev/null)"
  done <<<"$list"
  page="$(review_page)"
  if [ -n "$page" ]; then printf '\nReview page, to open for the user before asking what to approve: %s\n' "$page"
  else printf '\nNo review page could be written in %s: show the user the image files listed above.\n' "$SH_SNAPSHOT_CANDIDATES"; fi
  printf '\nDigest: %s\n' "$(current_digest)"
  exit 0
fi

# --approve
if [ -z "$list" ]; then
  echo "swift-harness: no new images wait for approval. Nothing changed." >&2
  exit 1
fi
if [ "$digest" != "$(current_digest)" ]; then
  echo "swift-harness: the images waiting changed since they were listed (a test ran again, or some were approved). Nothing approved: list them again with --status." >&2
  exit 1
fi
names=()
if [ $# -gt 0 ]; then
  for name in "$@"; do
    if [ -z "$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' <<<"$list")" ]; then
      echo "swift-harness: '$name' is not waiting for approval. Nothing approved." >&2
      exit 1
    fi
    names+=("$name")
  done
else
  while IFS=$'\t' read -r name _; do names+=("$name"); done <<<"$list"
fi

mkdir -p "$SH_ROOT/$baselines" || exit 1
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for name in "${names[@]}"; do
  status="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<<"$list")"
  png="$SH_ROOT/$baselines/$name.png"
  json="$SH_ROOT/$baselines/$name.json"
  if ! cp "$candidates/$name.png" "$png" ||
    ! relative_meta "$candidates/$name.json" "$now" "$status" >"$json.tmp" ||
    ! mv "$json.tmp" "$json"; then
    rm -f "$json.tmp"
    echo "swift-harness: cannot write $png. Stopped after the images listed above." >&2
    exit 1
  fi
  # Approved for every session open on the project (#61), not just the one that ran this.
  printf '%s %s\n%s %s\n' "$(sha "$png")" "$baselines/$name.png" "$(sha "$json")" "$baselines/$name.json" |
    sh_sessions_append "$state" snapshots-approved snapshots-start
  rm -f "$candidates/$name.png" "$candidates/$name.json" "$candidates/$name.diff.png" "$candidates/$name.result.json"
  printf 'Approved: %s/%s.png (%s)\n' "$baselines" "$name" "$status"
  sh_catch "snapshot baselines" approved "$name ($status)"
done
rm -f "$candidates/review.html" # it showed what waited before this approval
echo "Commit $baselines/ with the change that made these images."
exit 0
