#!/bin/bash
# Read-only porting scan of a macOS project toward iOS (#47). Run by /swift-harness:port-to-ios.
#
#   porting.sh scan    [project-dir]  one line per signal: level, module, file:line, signal
#   porting.sh summary [project-dir]  platforms, then one line per module, then dependencies
#
# Levels: blocks (macOS-only API compiled on iOS: the module does not build for iOS as is),
# adapt (available on iOS but behaves differently: hover, keyboard, menus, drag and drop),
# guarded (macOS-only API inside a branch iOS does not compile, such as #if os(macOS)).
# Text only: it reads Swift, C and Objective-C files, manifests and Package.resolved, and runs
# no project code.
# A module is Sources/<target> or Tests/<target> of a package, else the top folder.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
. "$here/lib.sh" </dev/null

mode="${1:-}"
root="$(cd "${2:-$PWD}" 2>/dev/null && pwd -P)" || { printf 'porting: no such folder: %s\n' "${2:-}"; exit 2; }
case "$mode" in scan | summary) ;; *) printf 'usage: porting.sh scan|summary [project-dir]\n'; exit 2 ;; esac

list() { git -C "$root" -c core.quotepath=off ls-files -co --exclude-standard "$@" 2>/dev/null; }
packages="$(list 'Package.swift' '*/Package.swift' | sed -e 's|/\{0,1\}Package\.swift$||' -e 's|^$|.|' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)"

scan() {
  list '*.swift' '*.c' '*.h' '*.m' '*.mm' | grep -vE '(^|/)(\.build|Pods|Carthage|DerivedData)/|(^|/)Package\.swift$' |
    (cd "$root" && tr '\n' '\0' | SH_PKGS="$packages" xargs -0 awk '
    BEGIN { pkgs = ENVIRON["SH_PKGS"] }
    function module(path,   n, i, p, rest, parts) {
      n = split(pkgs, P, "\n")
      for (i = 1; i <= n; i++) {
        p = P[i]
        if (p == "") continue
        if (p == ".") rest = path
        else if (index(path, p "/") == 1) rest = substr(path, length(p) + 2)
        else continue
        if (match(rest, /^(Sources|Tests)\/[^\/]+\//)) {
          split(rest, parts, "/")
          return (p == "." ? "" : p " › ") parts[1] "/" parts[2]
        }
        if (p != ".") return p
      }
      split(path, parts, "/")
      return (index(path, "/") ? parts[1] : ".")
    }
    # #if conditions evaluated for iOS: 1 compiled, 0 not compiled, 2 unknown (counts as compiled).
    function atom(c,   neg, v) {
      gsub(/^[ \t(]+|[ \t)]+$/, "", c)
      neg = 0
      while (substr(c, 1, 1) == "!") { neg = !neg; c = substr(c, 2); gsub(/^[ \t(]+/, "", c) }
      if (c ~ /^os\(iOS\)?$/ || c ~ /^canImport\(UIKit\)?$/) v = 1
      else if (c ~ /^os\((macOS|OSX|tvOS|watchOS|visionOS|xrOS)\)?$/ || c ~ /^canImport\((AppKit|Cocoa)\)?$/) v = 0
      else return 2
      return neg ? !v : v
    }
    function cond(c,   n, i, parts, v, r) {
      if (c ~ /&&/ && c ~ /\|\|/) return 2
      if (c ~ /\|\|/) { n = split(c, parts, "[|][|]"); r = 0; for (i = 1; i <= n; i++) { v = atom(parts[i]); if (v == 1) return 1; if (v == 2) r = 2 } return r }
      if (c ~ /&&/) { n = split(c, parts, "&&"); r = 1; for (i = 1; i <= n; i++) { v = atom(parts[i]); if (v == 0) return 0; if (v == 2) r = 2 } return r }
      return atom(c)
    }
    function active(   i) { for (i = 1; i <= depth; i++) if (val[i] == 0) return 0; return 1 }
    function hit(level, signal) {
      if (level == "blocks" && !active()) level = "guarded"
      else if (!active()) return
      printf "%s\t%s\t%s:%d\t%s\n", level, mod, FILENAME, FNR, signal
    }
    FNR == 1 { depth = 0; incomment = 0; inmls = 0; mod = module(FILENAME) }
    {
      line = $0
      # Block comments, then line comments and string contents, so text never counts as code.
      # Multiline string literals (""") are text, not code.
      if (inmls) { if (index(line, "\"\"\"")) { line = substr(line, index(line, "\"\"\"") + 3); inmls = 0 } else next }
      if (index(line, "\"\"\"")) {
        q = index(line, "\"\"\""); after = substr(line, q + 3)
        if (index(after, "\"\"\"")) line = substr(line, 1, q - 1) substr(after, index(after, "\"\"\"") + 3)
        else { line = substr(line, 1, q - 1); inmls = 1 }
      }
      if (incomment) { if (index(line, "*/")) { line = substr(line, index(line, "*/") + 2); incomment = 0 } else next }
      while (index(line, "/*")) {
        s = index(line, "/*"); e = index(substr(line, s + 2), "*/")
        if (e) line = substr(line, 1, s - 1) substr(line, s + e + 3)
        else { line = substr(line, 1, s - 1); incomment = 1 }
      }
      gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
      sub(/\/\/.*/, "", line)

      if (match(line, /^[ \t]*#if[ \t]/)) { depth++; c = substr(line, RLENGTH + 1); v = cond(c); val[depth] = v; taken[depth] = (v == 1); unk[depth] = (v == 2); next }
      if (match(line, /^[ \t]*#elseif[ \t]/)) {
        c = substr(line, RLENGTH + 1); v = cond(c)
        if (taken[depth]) v = 0
        val[depth] = v; if (v == 1) taken[depth] = 1; if (v == 2) unk[depth] = 1; next
      }
      if (line ~ /^[ \t]*#else/) { val[depth] = taken[depth] ? 0 : (unk[depth] ? 2 : 1); next }
      if (line ~ /^[ \t]*#endif/) { if (depth > 0) depth--; next }

      if (match(line, /^[ \t]*(@[A-Za-z_]+[ \t]+)*import[ \t]+(class[ \t]+|struct[ \t]+|enum[ \t]+|func[ \t]+)?(AppKit|Cocoa|Carbon|IOKit|ServiceManagement|OSAKit|Quartz|ScreenSaver|InputMethodKit|CoreWLAN|ApplicationServices|iTunesLibrary|DiscRecording|DiscRecordingUI|IOBluetooth|IOBluetoothUI|SecurityInterface|Automator|PreferencePanes|QuickLookUI|SystemExtensions|Virtualization|Hypervisor)([ \t.;]|$)/)) {
        m = line; sub(/^[ \t]*(@[A-Za-z_]+[ \t]+)*import[ \t]+(class[ \t]+|struct[ \t]+|enum[ \t]+|func[ \t]+)?/, "", m); sub(/[ \t.;].*/, "", m)
        hit("blocks", "import " m)
      }
      rest = line
      while (match(rest, /(^|[^A-Za-z0-9_])NS(App|Application|Window|WindowController|Workspace|Pasteboard|OpenPanel|SavePanel|StatusItem|StatusBar|Menu|MenuItem|Event|Alert|Image|Color|Font|View|ViewController|HostingView|HostingController|ViewRepresentable|ViewControllerRepresentable|VisualEffectView|Cursor|TextView|TableView|OutlineView|CollectionView|Screen|Sound|BezierPath|SplitView|SplitViewController|Toolbar|ToolbarItem|DocumentController|Document|Responder|Panel|Button|TextField|ScrollView|Appearance|GraphicsContext|BitmapImageRep|ImageView|Slider|PopUpButton|Popover|SharingServicePicker|Gesture[A-Za-z]*|DraggingInfo|Touch[A-Za-z]*)([^A-Za-z0-9_]|$)/)) {
        m = substr(rest, RSTART, RLENGTH); gsub(/^[^N]+|[^A-Za-z0-9_]+$/, "", m)
        hit("blocks", "AppKit " m)
        rest = substr(rest, RSTART + RLENGTH - 1)
        if (rest == "") break
      }
      if (match(line, /^[ \t]*#[ \t]*(include|import)[ \t]*<(AppKit|Cocoa|IOKit|Carbon|DiscRecording|CoreServices\/FSEvents|IOBluetooth)\//)) {
        m = line; sub(/^[ \t]*#[ \t]*(include|import)[ \t]*</, "", m); sub(/>.*/, "", m)
        hit("blocks", "#include <" m ">")
      }
      if (line ~ /(^|[^A-Za-z0-9_])FSEventStream[A-Za-z]*/) hit("blocks", "FSEvents (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])(kAudioHardwareProperty[A-Za-z]*|kAudioDeviceProperty[A-Za-z]*|AudioObjectGetPropertyData|AudioObjectSetPropertyData|AudioDeviceID|kAudioOutputUnitProperty_CurrentDevice)([^A-Za-z0-9_]|$)/) hit("blocks", "Core Audio HAL (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])MenuBarExtra([^A-Za-z0-9_]|$)/) hit("blocks", "MenuBarExtra (macOS only)")
      if (line ~ /^[ \t]*Settings[ \t]*\{/) hit("blocks", "Settings scene (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_.])Window[ \t]*\([ \t]*(""|LocalizedStringKey|Text)/) hit("blocks", "Window scene (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])(HSplitView|VSplitView)([^A-Za-z0-9_]|$)/) hit("blocks", "HSplitView/VSplitView (macOS only)")
      if (line ~ /\.(windowStyle|windowToolbarStyle|windowResizability|defaultPosition|onExitCommand|presentedWindowStyle)[ \t]*\(/) {
        m = line; sub(/.*\./, "", m); sub(/[ \t]*\(.*/, "", m); hit("blocks", "." m " (macOS only)")
      }
      if (line ~ /\.(withSecurityScope|securityScopeAllowOnlyReadAccess)([^A-Za-z0-9_]|$)/) hit("blocks", "security-scoped bookmark option (macOS only)")

      if (line ~ /\.onHover[ \t]*[({]/ || line ~ /\.onContinuousHover/) hit("adapt", "hover (needs a touch alternative)")
      if (line ~ /\.(keyboardShortcut|onKeyPress)[ \t]*\(/) hit("adapt", "keyboard (no keyboard on most iPhones)")
      if (line ~ /\.help[ \t]*\(/) hit("adapt", ".help tooltip (not shown on touch)")
      if (line ~ /(^|[^A-Za-z0-9_])(CommandMenu|CommandGroup)([^A-Za-z0-9_]|$)/ || line ~ /\.commands[ \t]*\{/) hit("adapt", "menu bar commands")
      if (line ~ /\.contextMenu[ \t]*[({]/) hit("adapt", "context menu (long press on iOS)")
      if (line ~ /\.(onDrop|dropDestination|draggable|onDrag)[ \t]*\(/) hit("adapt", "drag and drop")
      if (line ~ /\.popover[ \t]*\(/) hit("adapt", "popover (a sheet on iPhone)")
      if (line ~ /\.fileImporter[ \t]*\(|\.fileExporter[ \t]*\(/) hit("adapt", "file access (document picker on iOS)")
    }'
  )
}

if [ "$mode" = scan ]; then
  scan
  exit 0
fi

# ---------- summary ----------
signals="$(scan)"
printf 'Platforms declared:\n'
platforms="$(sh_platforms "$root")"
if [ -n "$platforms" ]; then printf '%s\n' "$platforms" | awk -F'\t' '{ printf "- %s (%s)\n", $1, $2 }'
else printf -- '- none in project.pbxproj or Package.swift\n'; fi

printf '\nModules:\n'
list '*.swift' '*.c' '*.h' '*.m' '*.mm' | grep -vE '(^|/)(\.build|Pods|Carthage|DerivedData)/|(^|/)Package\.swift$' |
  SH_PKGS="$packages" awk '
    BEGIN { pkgs = ENVIRON["SH_PKGS"] }
    function module(path,   n, i, p, rest, parts) {
      n = split(pkgs, P, "\n")
      for (i = 1; i <= n; i++) {
        p = P[i]
        if (p == "") continue
        if (p == ".") rest = path
        else if (index(path, p "/") == 1) rest = substr(path, length(p) + 2)
        else continue
        if (match(rest, /^(Sources|Tests)\/[^\/]+\//)) { split(rest, parts, "/"); return (p == "." ? "" : p " › ") parts[1] "/" parts[2] }
        if (p != ".") return p
      }
      split(path, parts, "/")
      return (index(path, "/") ? parts[1] : ".")
    }
    { files[module($0)]++ }
    END { for (m in files) printf "%s\t%d\n", m, files[m] }' | sort |
  while IFS=$'\t' read -r mod count; do
    of() { printf '%s\n' "$signals" | awk -F'\t' -v l="$1" -v m="$mod" '$1 == l && $2 == m'; }
    blocks="$(of blocks)"; adapt="$(of adapt)"; guarded="$(of guarded)"
    n_b="$(printf '%s' "$blocks" | grep -c . || true)"; n_a="$(printf '%s' "$adapt" | grep -c . || true)"; n_g="$(printf '%s' "$guarded" | grep -c . || true)"
    if [ "$n_b" -gt 0 ]; then
      first="$(printf '%s\n' "$blocks" | head -3 | awk -F'\t' '{ printf "%s%s %s", (NR > 1 ? "; " : ""), $3, $4 }')"
      line="does not build for iOS as is (static): $n_b macOS-only use(s), $first$([ "$n_b" -gt 3 ] && printf '; …')"
    else
      line="no macOS-only API compiled for iOS"
    fi
    [ "$n_g" -eq 0 ] || line="$line; $n_g behind #if (not compiled on iOS)"
    [ "$n_a" -eq 0 ] || line="$line; $n_a to adapt ($(printf '%s\n' "$adapt" | cut -f4 | sed 's/ (.*//' | sort | uniq -c | awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "%s%s %s", (NR > 1 ? ", " : ""), c, $0 }'))"
    printf -- '- %s (%s source file(s)): %s\n' "$mod" "$count" "$line"
  done

printf '\nDependencies (Package.resolved):\n'
resolved="$(list 'Package.resolved' '*/Package.resolved')"
if [ -z "$resolved" ]; then
  printf -- '- none pinned\n'
else
  while IFS= read -r r; do
    jq -r '(.pins // .object.pins // [])[] | [(.identity // .package // "" | ascii_downcase), (.location // .repositoryURL // "")] | @tsv' "$root/$r" 2>/dev/null
  done <<<"$resolved" | sort -u | while IFS=$'\t' read -r id url; do
    [ -n "$id" ] || continue
    manifest=""
    for d in "$root/.build/checkouts/$id" "$root"/*/.build/checkouts/"$id"; do
      [ -f "$d/Package.swift" ] && { manifest="$d/Package.swift"; break; }
    done
    if [ -z "$manifest" ]; then
      printf -- '- %s (%s): platforms not checked, no local checkout\n' "$id" "$url"
    else
      decl="$(grep -oE '\.(macOS|iOS|tvOS|watchOS|visionOS|macCatalyst)\(' "$manifest" | tr -d '.(' | sort -u | paste -sd, - | sed 's/,/, /g')"
      printf -- '- %s (%s): %s\n' "$id" "$url" "${decl:-no platforms: declared (all platforms, default minimums)}"
    fi
  done
fi
printf '\nStatic analysis only: a module without macOS-only API can still fail to build for iOS (dependencies, resources, build settings). Only a build for iOS proves it builds.\n'
