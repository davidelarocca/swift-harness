#!/bin/bash
# One simulator or UI test run at a time on this machine (#74).
#
#   simulator-lock.sh run [--wait SECONDS] [--name TEXT] -- COMMAND [ARG...]
#       runs COMMAND while holding the lock, and exits with its exit code. When another run holds
#       the lock: exit 75 with nothing run, or wait up to SECONDS for it.
#   simulator-lock.sh status
#       says whether the lock is free, or who holds it. Exit 0.
#
# Simulators and UI tests are heavy, and every session of the user shares them: two at once slow
# each other down, steal the screen, or fail for reasons that are not in the code. Put this in
# front of the commands that start one (a verify script's UI test step, a test robot):
#   "${CLAUDE_PLUGIN_ROOT}/scripts/simulator-lock.sh" run --wait 600 -- xcodebuild test ...
# porting.sh test-check takes the same lock by itself. The lock is a folder in
# /tmp/swift-harness-<uid> (SWIFT_HARNESS_LOCK_DIR moves it); one whose process is gone is taken
# over. It orders runs that ask for it: a command that does not ask is not stopped.

set -u
. "$(dirname "$0")/lib.sh" </dev/null

usage() { echo "usage: simulator-lock.sh run [--wait SECONDS] [--name TEXT] -- COMMAND [ARG...] | simulator-lock.sh status" >&2; exit 2; }

case "${1:-}" in
  status)
    [ $# -eq 1 ] || usage
    lock="$(sh_sim_lock_path)"
    pid="$(sed -n 1p "$lock/holder" 2>/dev/null)"
    case "$pid" in '' | *[!0-9]*) pid=0 ;; esac
    if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
      printf 'busy: %s (pid %s)\n' "$(sed -n 3p "$lock/holder" 2>/dev/null)" "$pid"
    elif [ "$pid" -eq 0 ] && [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      printf 'busy: a run that is starting\n'
    else
      printf 'free\n'
    fi
    exit 0
    ;;
  run) shift ;;
  *) usage ;;
esac

wait=0
name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; wait="$2"; shift 2 ;;
    --name) [ $# -ge 2 ] || usage; name="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage
[ -n "$name" ] || name="$(basename "$1") in $PWD"

trap sh_sim_lock_release EXIT
if ! sh_sim_lock_wait "$name" "$wait"; then
  printf 'simulator-lock: busy: %s. Nothing ran.\n' "$SH_SIM_LOCK_HOLDER" >&2
  exit 75
fi
"$@"
