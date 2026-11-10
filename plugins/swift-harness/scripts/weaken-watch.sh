#!/bin/bash
# Stop: tell the user and the agent when this session made a check weaker (#146). The quickest
# way to turn a failing check green is to weaken it: remove a test or its assertions, skip it,
# silence a lint rule. Each can be right; what matters is that the user sees it. Compares the
# list taken by session-start.sh (sh_weaken_list) with the code now, and names each change by
# file: tests or assertions removed, a test file removed, skips added (XCTSkip, .disabled(...),
# #if false), a larger tolerance: in a test file, swiftlint:disable added, in .swiftlint.yml a
# rule disabled, no longer opted in or no longer in only_rules, or a path excluded, a layout
# contract row removed or its Min lowered, and a registry component gone from Components
# without being retired. A test file renamed with the same counts is not a removal, nor a
# component that keeps its ID under a new name. Text only, no project code runs. Said once per
# set, recorded in the catch log. Never blocks.

. "$(dirname "$0")/lib.sh"
sh_init || exit 0
export LC_ALL=C
state="$(sh_state_dir)" || exit 0
sess="$(sh_session_path "$state")"
start="$sess/weaken-start"
[ -f "$start" ] || exit 0 # no list for this session

now="$(mktemp -t swift-harness-weaken.XXXXXX)"
sh_weaken_list >"$now"
report="$(awk -F'\t' '
  function tup(a, f) { return (a["tests" FS f FS "-"] + 0) "," (a["asserts" FS f FS "-"] + 0) "," (a["skips" FS f FS "-"] + 0) }
  function plural(n, w) { return n " " w (n == 1 ? "" : "s") }
  # A layout size "<width>x<height>" or "<width>", "-" for none: true when now is below start.
  function lower(now, was,   p, q) {
    if (was == "-") return 0
    if (now == "-") return 1
    split(was, p, /x|X|×/); split(now, q, /x|X|×/)
    if (q[1] + 0 < p[1] + 0) return 1
    return ((2 in p) && (2 in q) && q[2] + 0 < p[2] + 0)
  }
  NR == FNR { s[$1 FS $2 FS $3] = $4; if ($1 == "tests") sf[$2] = 1; next }
  { n[$1 FS $2 FS $3] = $4; if ($1 == "tests") nf[$2] = 1
    if ($1 == "registry") { id = $3; sub(/ .*/, "", id); nid[id] = 1 } }
  END {
    # A test file gone, and a new one with the same counts: a rename, compared as one file.
    for (g in sf) if (!(g in nf)) {
      t = tup(s, g)
      for (f in nf) if (!(f in sf) && !(f in from) && tup(n, f) == t) { from[f] = g; renamed[g] = 1; break }
    }
    for (g in sf) if (!(g in nf) && !(g in renamed) && (s["tests" FS g FS "-"] + s["asserts" FS g FS "-"]) > 0) {
      gone[g] = 1
      print g ": file removed (" plural(s["tests" FS g FS "-"] + 0, "test") ", " plural(s["asserts" FS g FS "-"] + 0, "assertion") ")"
    }
    for (k in s) keys[k] = 1
    for (k in n) keys[k] = 1
    for (k in keys) {
      split(k, p, FS); kind = p[1]; f = p[2]; name = p[3]
      if ((f in gone) || (f in renamed)) continue
      has = (k in n) # before n[k] is read: reading an element creates it
      a = (f in from) ? s[kind FS from[f] FS name] + 0 : s[k] + 0
      b = n[k] + 0
      if (kind == "tests" && b < a) print f ": " plural(a - b, "test") " removed (" a " -> " b ")"
      else if (kind == "asserts" && b < a) print f ": " plural(a - b, "assertion") " removed (" a " -> " b ")"
      else if (kind == "skips" && b > a) print f ": " plural(b - a, "skip") " added (" a " -> " b ")"
      else if (kind == "lint-disable" && b > a) print f ": " (b - a) " swiftlint:disable added (" a " -> " b ")"
      else if (kind == "lint-off" && b > a) print f ": rule " name " disabled"
      else if (kind == "lint-optin" && b < a) print f ": rule " name " no longer opted in"
      else if (kind == "lint-only" && b < a) print f ": rule " name " removed from only_rules"
      else if (kind == "lint-excluded" && b > a) print f ": " name " excluded from lint"
      else if (kind == "tolerance" && a != b) {
        # Per file: the largest tolerance gone and the largest one new.
        g = (f in from) ? from[f] : f
        if (b > a) { tadd[g] = 1; if (!(g in tnew) || name + 0 > tnew[g] + 0) tnew[g] = name; tfile[g] = f }
        else if (!(g in told) || name + 0 > told[g] + 0) told[g] = name
      }
      else if (kind == "layout-min") {
        if (!has) print f ": layout row " name " removed (its sizes are no longer measured)"
        else if (lower(n[k], s[k])) print f ": Min of " name " lowered (" s[k] " -> " n[k] ")"
      }
      else if (kind == "registry" && b < a) {
        id = name; sub(/ .*/, "", id)
        if (!(("registry-retired" FS f FS id) in n) && !(id in nid)) print f ": " name " no longer under Components (no longer checked)"
      }
    }
    for (g in tadd) {
      if (!(g in told)) print tfile[g] ": tolerance " tnew[g] " added"
      else if (tnew[g] + 0 > told[g] + 0) print tfile[g] ": tolerance raised (" told[g] " -> " tnew[g] ")"
    }
  }' "$start" "$now" | sort)"
rm -f "$now"
[ -n "$report" ] || exit 0

sum="$(printf '%s' "$report" | shasum | cut -d' ' -f1)"
[ "$sum" = "$(cat "$sess/weaken-warned" 2>/dev/null)" ] && exit 0
printf '%s' "$sum" >"$sess/weaken-warned"

count="$(printf '%s\n' "$report" | grep -c .)"
sh_catch "weakened checks" reported "$count change(s) that make a check weaker"
msg="swift-harness: this session made checks weaker. Each change can be right, but a failing check made to pass this way is not fixed:
$(printf '%s\n' "$report" | head -20 | sed 's/^/- /')$([ "$count" -le 20 ] || printf '\n- and %s more' "$((count - 20))")
Keep only the changes the user agrees with, and restore the others (git diff -- <file>, git checkout -- <file>)."
jq -n --arg msg "$msg" '{systemMessage: $msg, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $msg}}'
exit 0
