#!/bin/bash
# Approve new snapshot images as baselines (#9). Run by the user through
# /swift-harness:approve-snapshots, never by a hook.
#
#   snapshots.sh --status [--project DIR]                    list the images waiting, and a digest
#   snapshots.sh --approve DIGEST [--project DIR] [NAME...]  copy them into the baselines folder,
#                                                            only if DIGEST is still current
#
# The project's tests (templates/tests/Snapshot.swift) never write a baseline: a missing or
# different image leaves <name>.png, .json, .diff.png and .result.json in
# .build/swift-harness/snapshots/. Approving copies the image and its metadata into
# `snapshots.path` (default snapshots/) and records it, so the end-of-turn notice
# (snapshot-watch.sh) does not report it as changed without approval.

usage() {
  echo "usage: snapshots.sh --status [--project DIR] | --approve DIGEST [--project DIR] [NAME...]" >&2
  exit 2
}

action="${1:-}"
digest=""
case "$action" in
  --status) shift ;;
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
[ "$action" = "--status" ] && [ $# -gt 0 ] && usage

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

if [ "$action" = "--status" ]; then
  printf 'Project: %s\nBaselines: %s/\n' "$SH_ROOT" "$baselines"
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
    ! jq --arg now "$now" --arg status "$status" '. + {approved: $now, approvedFrom: $status}' "$candidates/$name.json" >"$json.tmp" ||
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
echo "Commit $baselines/ with the change that made these images."
exit 0
