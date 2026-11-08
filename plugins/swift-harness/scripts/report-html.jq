# The static report page (#87), rendered by report.sh --html. Every value that comes from the
# repository, the config or the log goes through @html. No script, no external resource.
# Inputs: $summary (report.sh's summary), $ev (the last end-of-turn record or null), $recent
# (the last catch-log lines, newest first), $root, $label, $now (the current code's
# identity), $head, $made, $log, $evfile.

def esc: tostring | @html;
# Green only for a check that ran and passed on the current code (rules of discussion #50).
def cls($result; $current):
  if ($current | not) then "none"
  elif $result == "passed" then "ok"
  elif $result == "partial" or $result == "checked" then "warn"
  elif $result == "failed" or $result == "not-verified" then "bad"
  else "none" end;
def badge($text; $c): "<span class=\"b \($c)\">\($text | esc)</span>";

($ev != null and ($ev.code // "") == $now) as $current
| "<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">
<title>swift-harness report</title>
<style>
:root { --bg: #fff; --fg: #1d1d1f; --mute: #6e6e73; --line: #d2d2d7; --ok: #1a7f37; --warn: #9a6700; --bad: #cf222e; --none: #6e6e73; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f5f5f7; --mute: #a1a1a6; --line: #3a3a3c; --ok: #3fb950; --warn: #d29922; --bad: #f85149; --none: #8e8e93; } }
body { background: var(--bg); color: var(--fg); font: 14px/1.45 -apple-system, system-ui, sans-serif; max-width: 960px; margin: 0 auto; padding: 24px 16px; }
h1 { font-size: 20px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 28px 0 8px; }
.mute, .src { color: var(--mute); } .src { font-size: 12px; margin-top: 6px; }
table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-weight: 600; color: var(--mute); font-size: 12px; }
.b { display: inline-block; padding: 1px 8px; border-radius: 10px; border: 1px solid currentColor; font-size: 12px; white-space: nowrap; }
.ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); } .none { color: var(--none); }
code { font: 12px ui-monospace, Menlo, monospace; overflow-wrap: anywhere; }
</style></head><body>
<h1>swift-harness report</h1>
<div class=\"mute\">\($root | esc) · HEAD \($head | esc) · made \($made | esc)</div>

<h2>Verified on this code</h2>"
+ (if $ev == null then
    "<p>\(badge("no record"; "none")) No end-of-turn check has run in this project yet.</p>"
  else
    "<p>\(badge($ev.outcome // "unknown"; cls($ev.outcome // ""; $current))) "
    + (if $current then "The last end-of-turn record is about the code as it is now."
       else "The last end-of-turn record is about an earlier state of the code: nothing here is verified for the current code until a turn ends again." end)
    + (if ($ev.note // "") != "" then " <span class=\"mute\">\($ev.note | esc)</span>" else "" end)
    + "</p>"
    + (if (($ev.checks // []) | length) == 0 then "<p class=\"mute\">No check in the record.</p>" else
      "<table><tr><th>Check</th><th>Result</th><th>Detail</th></tr>"
      + ([$ev.checks[] | "<tr><td><code>\(.name | esc)</code></td><td>\(badge(.result; cls(.result; $current)))</td><td>\((.detail // "") | esc)</td></tr>"] | join(""))
      + "</table>" end)
    + "<div class=\"src\">Source: <code>\($evfile | esc)</code>, written by the end-of-turn check at \(($ev.time // "") | esc), code \(($ev.code // "")[0:12] | esc).</div>"
  end)
+ "
<h2>What the checks caught, \($label | esc)</h2>"
+ (if $summary.events == 0 then "<p class=\"mute\">Nothing in the catch log.</p>" else
    "<table><tr><th>Check</th><th>Blocked</th><th>Reported</th><th>Asked</th><th>Fixed by Claude</th><th>Left failing</th><th>Approved by you</th><th>Last</th></tr>"
    + ([$summary.checks[] | "<tr><td><code>\(.check | esc)</code></td><td>\(.blocked)</td><td>\(.reported)</td><td>\(.asked)</td><td>\(.fixed)</td><td>\(.left_failing)</td><td>\(.approved)</td><td>\((.last // "") | esc)</td></tr>"] | join(""))
    + "</table>"
    + (if ($summary.skipped | length) == 0 then "" else
      "<h2>Not checked</h2><table><tr><th>Check</th><th>Times</th><th>Why</th></tr>"
      + ([$summary.skipped[] | "<tr><td><code>\(.check | esc)</code></td><td>\(.times)</td><td>\(.why | map(esc) | join("<br>"))</td></tr>"] | join(""))
      + "</table>" end)
    + "<h2>Latest entries</h2><table><tr><th>Time</th><th>Check</th><th>Kind</th><th>What</th></tr>"
    + ([$recent[] | "<tr><td class=\"mute\">\((.time // "") | esc)</td><td><code>\((.check // "") | esc)</code></td><td>\((.kind // "") | esc)</td><td>\((.what // "") | esc)</td></tr>"] | join(""))
    + "</table>"
  end)
+ "<div class=\"src\">Source: <code>\($log | esc)</code>, kept on this machine by the hooks; it counts what they saw, not what they prevented.</div>
<p class=\"src\">Read-only: this page changes no setting and no approval.</p>
</body></html>"
