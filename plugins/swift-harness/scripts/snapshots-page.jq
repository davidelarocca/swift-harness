# The page the user looks at before approving snapshot images, rendered by snapshots.sh --status.
# One static file: every value that comes from the project goes through @html, every path
# through @uri. No script, no external resource; the images are the project's own files.
# Made to be read in seconds: a table of what waits, then one image set per component (the
# variant that changed most). Its other sizes and appearances are folded under it only when they
# show the same change in the same place; any other is shown open, so that answering "all"
# never approves an image that differs in a way the user could not see.
# Inputs: $items (one object per image waiting: name, status, reason, meta, baseline, diff,
# old), $project (the project folder's name), $baselines (the baselines folder, relative to
# the project), $up (the way from the page's folder back to the project root), $made.

def esc: tostring | @html;
def url: split("/") | map(@uri) | join("/");
def count($n; $one; $many): "\($n) \(if $n == 1 then $one else $many end)";
# "85 of 151200 pixels differ (0.06%)": the share of pixels that changed, when the test gave it.
def percent: ((.reason // "") | capture("\\((?<p>[0-9.]+)%\\)") | .p | tonumber)? // null;
# "the size changed from 200x48 to 200x64 pt"
def resized: ((.reason // "") | capture("the size changed from (?<a>[0-9.x]+) to (?<b>[0-9.x]+) pt") | "\(.a) to \(.b) pt")? // null;
# "within x 96-110, y 118-126 pt from the top left": where to look for a small change.
def region: ((.reason // "") | capture("within (?<r>x [0-9.-]+, y [0-9.-]+ pt from the top left)") | .r)? // null;
def kind:
  if .status == "missing" then "new"
  elif .status == "not-compared" then "other Mac"
  elif resized then "size"
  else "changed" end;
def kindtext:
  if . == "new" then "new: no approved image yet"
  elif . == "other Mac" then "not compared: the approved image was made on another macOS version or display scale"
  elif . == "size" then "the size changed"
  else "changed" end;
# Changed images first, the largest change on top; then new ones; then the ones not compared.
def rank: if . == "size" then 0 elif . == "changed" then 1 elif . == "new" then 2 else 3 end;
# The same change as $shown: pixels changed in the same region, the same change of size, or both
# not compared. A new image is never like another: nothing was approved to compare it with.
def like($shown):
  .kind == $shown.kind
  and (if .kind == "changed" then region != null and region == ($shown | region)
       elif .kind == "size" then resized == ($shown | resized)
       else .kind == "other Mac" end);
def title: [(.meta.screen // .name), (.meta.state // ""), (.meta.locale // "")] | map(select(. != "")) | join(" · ");
def variant: [(.meta.contractSize // .meta.size // ""), (.meta.appearance // "")] | map(select(. != "")) | join(", ");
def amount:
  if .kind == "size" then (resized // "")
  elif .percent == null then ""
  elif .percent < 0.01 then "under 0.01% of pixels"
  else "\(.percent)% of pixels" end;
# Images are saved in pixels: shown at their size in points, so 2x images are not doubled.
def width: ((.meta.size // "") | capture("^(?<w>[0-9.]+)x") | .w | tonumber)? // null;
def img($src; $alt): "<img loading=\"lazy\" src=\"\($src | url)\" alt=\"\($alt | esc)\"" + (if width then " style=\"width: \(width)px\"" else "" end) + ">";
def cell($label; $body): "<figure><figcaption>\($label | esc)</figcaption>\($body)</figure>";
def badge: "<span class=\"b \(if . == "new" then "new" elif . == "other Mac" then "other" else "" end)\">\(esc)</span>";
# One image waiting: what it is, then before, now and the changed pixels side by side.
def shown:
  "<h3>\(variant | if . == "" then "image" else . end | esc) <span class=\"mute\">· \(.kind | kindtext | esc)\(amount as $a | if $a != "" and .kind != "size" then " · " + $a else "" end)\(if .kind == "size" then ", from " + amount else "" end)\(region as $r | if $r then ", within " + ($r | esc) else "" end)</span></h3>"
  + "<div class=\"row\">"
  + (if .old then cell("Before (approved" + (if .baseline.os then ", made on macOS \(.baseline.os)" else "" end) + ")"; img($up + $baselines + "/" + .name + ".png"; "approved image")) else "" end)
  + cell("Now"; img(.name + ".png"; "new image"))
  + (if .diff then cell("Changes in red"; img(.name + ".diff.png"; "changed pixels in red")) else "" end)
  + "</div>"
  + "<p class=\"mute\"><code>\(.name | esc)</code></p>";

($items | map(. + {kind: kind, percent: percent, title: title})) as $all
| ($all | group_by(.title) | map({
    title: .[0].title,
    kind: (map(.kind) | sort_by(rank) | .[0]),
    most: (map(.percent // 0) | max),
    # The variant that changed most first: it is the one shown open.
    images: sort_by([(.kind | rank), -(.percent // 0), (if .meta.appearance == "dark" then 1 else 0 end), .name])
  }) | sort_by([(.kind | rank), -.most, .title])) as $groups
| "<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src file: 'self'\">
<title>Snapshots waiting for approval</title>
<style>
:root { --bg: #fff; --fg: #1d1d1f; --mute: #6e6e73; --line: #d2d2d7; --card: #f5f5f7; --warn: #9a6700; --new: #0969da; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f5f5f7; --mute: #a1a1a6; --line: #3a3a3c; --card: #2c2c2e; --warn: #d29922; --new: #58a6ff; } }
body { background: var(--bg); color: var(--fg); font: 14px/1.45 -apple-system, system-ui, sans-serif; max-width: 1280px; margin: 0 auto; padding: 24px 16px; }
h1 { font-size: 20px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 32px 0 4px; } h3 { font-size: 13px; margin: 14px 0 6px; font-weight: 600; }
.mute { color: var(--mute); font-weight: 400; } p { margin: 6px 0; }
table { border-collapse: collapse; margin: 12px 0; } th, td { text-align: left; padding: 5px 16px 5px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-weight: 600; color: var(--mute); font-size: 12px; } a { color: inherit; }
.b { display: inline-block; padding: 1px 8px; border-radius: 10px; border: 1px solid currentColor; font-size: 12px; white-space: nowrap; color: var(--warn); }
.b.new { color: var(--new); } .b.other { color: var(--mute); }
.row { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; padding: 12px; background: var(--card); border-radius: 8px; overflow-x: auto; }
figure { margin: 0; } figcaption { font-size: 12px; color: var(--mute); margin-bottom: 4px; }
img { display: block; max-width: 100%; height: auto; border: 1px solid var(--line); }
details { margin-top: 10px; } summary { cursor: pointer; color: var(--mute); }
code { font: 12px ui-monospace, Menlo, monospace; overflow-wrap: anywhere; }
</style></head><body>
<h1>\(count($all | length; "snapshot image waits"; "snapshot images wait")) for your approval, in \(count($groups | length; "component"; "components"))</h1>
<p>Approving means: from now on each of these must look like its <b>Now</b> image, and the tests compare with it. Approve what is meant to look like this; what is not is a defect for Claude to fix.</p>
<p class=\"mute\">Nothing is approved by looking at this page. Back in Claude Code, answer: all, the names to approve, or none. The largest changes are first, and each component shows the variant that changed most. Its other sizes and appearances are folded under it when they show the same change in the same place; the others are shown open.</p>
<table><tr><th>Component</th><th>Images</th><th>What</th><th>Largest change</th></tr>"
+ ($groups | to_entries | map(
    "<tr><td><a href=\"#g\(.key)\">\(.value.title | esc)</a></td><td>\(.value.images | length)</td>"
    + "<td>\(.value.kind | badge)</td><td>\(.value.images[0] | amount | esc)</td></tr>"
  ) | join("\n"))
+ "</table>"
+ ($groups | to_entries | map(
    "<h2 id=\"g\(.key)\">\(.value.title | esc)</h2>"
    + (.value.images[0] as $first
      | (.value.images[1:] | map(select(like($first)))) as $folded
      | ($first | shown)
      + (.value.images[1:] | map(select(like($first) | not) | shown) | join("\n"))
      + (if ($folded | length) > 0 then
          "<details><summary>\(count($folded | length; "more image"; "more images")) of this component with the same change in the same place: \($folded | map(variant) | join("; ") | esc)</summary>"
          + ($folded | map(shown) | join("\n")) + "</details>"
        else "" end))
  ) | join("\n"))
+ "<p class=\"mute\" style=\"margin-top: 32px\">\($project | esc) · made \($made | esc) by swift-harness. A test run or an approval changes what waits: the approval command makes this page again.</p>
</body></html>"
