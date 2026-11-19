#!/bin/bash
# Read-only porting scan of a macOS project toward iOS (#47). Run by /swift-harness:port-to-ios.
#
#   porting.sh scan    [project-dir]  one line per signal: level, module, file:line, signal
#   porting.sh summary [project-dir]  platforms, then one line per module, then dependencies
#   porting.sh build-check [project-dir] [--target NAME]... [--ios VERSION] [--keep]
#                                     builds each package target for the iOS Simulator, on a COPY
#   porting.sh test-check [project-dir] [--target NAME]... [--device NAME] [--keep]
#                                     runs package test targets on an iPhone simulator, on a COPY
#   porting.sh ratchet [project-dir]  exit 1 when a ported module has new macOS-only code
#   porting.sh ratchet [project-dir] --record [--module MODULE]...
#                                     adds modules to the ratchet and accepts their current uses
#
# The ratchet (#73) keeps what is ported from going back: its file (porting.ratchet in
# .claude/swift-harness.json, default docs/PORTING_RATCHET.tsv) lists the modules that build for
# iOS, as summary names them, and the macOS-only uses accepted in each. The end-of-turn check
# runs `ratchet` and fails on a "blocks" signal of the scan that is not accepted, with file:line.
# Recording again accepts what is there now: that is the user's decision, and weaken-watch.sh
# tells the user when a session did it. Text only, like scan; it works for packages and for
# folders of an Xcode project alike.
#
# An Xcode project (#171), when there is no root Package.swift or with --project or --scheme:
# build-check builds each scheme (every scheme `xcodebuild -list` shows, or --scheme) for the
# generic iOS Simulator destination with CODE_SIGNING_ALLOWED=NO, on the same kind of copy; a
# scheme with no iOS destination is reported as NOT iOS, not as a failure. test-check runs
# `xcodebuild test` on the named schemes. --project picks a workspace or project at the root when
# there are several (a workspace is preferred to a project otherwise).
#
# Exit codes: build-check 0 when nothing failed (a scheme with no iOS destination is not a
# failure), 1 when a target or scheme failed; test-check 0 only when tests ran and none failed;
# 1 also for a missing tool, SDK, simulator or project; 2 for a usage error.
#
# build-check and test-check are the only modes that run anything. build-check copies the project to a temporary folder
# (no .git, .build, DerivedData, secrets), runs `swift build --target NAME --triple
# arm64-apple-ios<V>-simulator` there, so the project's own manifest and compiler run on the copy
# and nothing in the project changes. Package dependencies, if any, are fetched into the copy.
# Targets are the folders of Sources/ of the root package (override with --target). Output, one
# line per target: PASS, or FAIL with the first errors and the module each came from, because a
# target that depends on a failing one reports the same errors. V defaults to the SDK's major
# version. It proves a build, nothing else: no test ran, no UI was looked at, the Mac app was not
# built. A static scan misses what only the compiler sees (C APIs such as fenv.h).
#
# test-check makes the same kind of copy (also without a root .xcodeproj or .xcworkspace, so
# xcodebuild opens the package), writes a temporary scheme into it that builds and runs only the
# test targets (the folders of Tests/, or --target), and runs `xcodebuild test` on the first iPhone
# simulator of the newest iOS runtime (or --device NAME). -only-testing is not enough: it still
# builds every target, macOS-only ones too. The counts and the first failures come from the
# result bundle; tests that do not build show the compiler's first errors. A simulator it found
# shut down is shut down again. No UI is looked at, the Mac app is not built, a skipped test
# proves nothing.
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
[ $# -eq 0 ] || shift
dir_arg=""
case "${1:-}" in --* | "") ;; *) dir_arg="$1"; shift ;; esac
root="$(cd "${dir_arg:-$PWD}" 2>/dev/null && pwd -P)" || { printf 'porting: no such folder: %s\n' "$dir_arg"; exit 2; }
usage() { printf 'usage: porting.sh scan|summary [project-dir]\n       porting.sh build-check [project-dir] [--target NAME]... [--ios VERSION] [--keep]\n       porting.sh build-check [project-dir] [--project NAME] [--scheme NAME]... [--keep]\n       porting.sh test-check [project-dir] [--target NAME]... [--device NAME] [--keep]\n       porting.sh test-check [project-dir] [--project NAME] --scheme NAME... [--device NAME] [--keep]\n       porting.sh ratchet [project-dir] [--record [--module MODULE]...]\n'; exit 2; }
case "$mode" in scan | summary) [ $# -eq 0 ] || usage ;; build-check | test-check | ratchet) ;; *) usage ;; esac

list() { git -C "$root" -c core.quotepath=off ls-files -co --exclude-standard "$@" 2>/dev/null; }
packages="$(list 'Package.swift' '*/Package.swift' | sed -e 's|/\{0,1\}Package\.swift$||' -e 's|^$|.|' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)"

scan() { # $1, optional: folders, one per line; only the files under them are read
  list '*.swift' '*.c' '*.h' '*.m' '*.mm' | grep -vE '(^|/)(\.build|Pods|Carthage|DerivedData)/|(^|/)Package\.swift$' |
    SH_ONLY="${1:-}" awk 'BEGIN { n = split(ENVIRON["SH_ONLY"], P, "\n") }
      n == 0 { print; next }
      { for (i = 1; i <= n; i++) if (P[i] != "" && index($0, P[i] "/") == 1) { print; next } }' |
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
    FNR == 1 { depth = 0; incomment = 0; inmls = 0; coreaudio = 0; mod = module(FILENAME) }
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
      if (line ~ /(^|[^A-Za-z0-9_])(fenv_t|fegetenv|fesetenv|feholdexcept|feupdateenv)([^A-Za-z0-9_]|$)/) hit("blocks", "floating-point environment, fenv (not visible to Swift on iOS)")
      if (line ~ /\.(withSecurityScope|securityScopeAllowOnlyReadAccess)([^A-Za-z0-9_]|$)/) hit("blocks", "security-scoped bookmark option (macOS only)")
      if (line ~ /\.loadInProcess([^A-Za-z0-9_]|$)/) hit("blocks", ".loadInProcess (audio unit option, macOS only)")
      # APIs many Mac apps use that iOS does not have (#173).
      if (line ~ /(^|[^A-Za-z0-9_.])(Process[ \t]*\([ \t]*\)|Process\.(run|launchedProcess)[ \t]*\(|NSTask)([^A-Za-z0-9_]|$)/ || line ~ /:[ \t]*Process[ \t]*[=,){]/) hit("blocks", "Process (no child processes on iOS)")
      if (line ~ /(^|[^A-Za-z0-9_])(NSAppleScript|NSUserAppleScriptTask|NSUserUnixTask|NSUserAutomatorTask)([^A-Za-z0-9_]|$)/) hit("blocks", "AppleScript and user scripts (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])(homeDirectoryForCurrentUser|NSHomeDirectoryForUser)([^A-Za-z0-9_]|$)/ || line ~ /homeDirectory[ \t]*\([ \t]*forUser:/) hit("blocks", "home folder of the user (macOS only; the app container on iOS)")
      if (line ~ /(^|[^A-Za-z0-9_])(DistributedNotificationCenter|NSDistributedNotificationCenter)([^A-Za-z0-9_]|$)/) hit("blocks", "distributed notifications (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])(NSUserNotification|NSUserNotificationCenter)([^A-Za-z0-9_]|$)/) hit("blocks", "NSUserNotification (macOS only; UserNotifications on both)")
      if (line ~ /NSXPCConnection[ \t]*\([ \t]*machServiceName:/) hit("blocks", "XPC to a Mach service (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])(CGWindowList[A-Za-z]*|CGEvent[A-Za-z]*|CGDisplay[A-Za-z]*|CGMainDisplayID)([^A-Za-z0-9_]|$)/) hit("blocks", "Core Graphics window, event or display API (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])(AXUIElement[A-Za-z]*|AXIsProcessTrusted[A-Za-z]*|AXObserver[A-Za-z]*)([^A-Za-z0-9_]|$)/) hit("blocks", "accessibility automation, AXUIElement (macOS only)")
      if (line ~ /(^|[^A-Za-z0-9_])Host\.current[ \t]*\(/) hit("blocks", "Host (macOS only)")
      # On macOS AudioToolbox brings CoreAudio with it; on iOS it does not, and the buffer list
      # pointer lives there. An import inside a branch iOS does not compile does not count.
      if (active() && line ~ /^[ \t]*(@[A-Za-z_]+[ \t]+)*import[ \t]+(CoreAudio|AVFAudio|AVFoundation)([ \t.;]|$)/) coreaudio = 1
      if (!coreaudio && line ~ /(^|[^A-Za-z0-9_])UnsafeMutableAudioBufferListPointer([^A-Za-z0-9_]|$)/) hit("blocks", "UnsafeMutableAudioBufferListPointer without import CoreAudio (AudioToolbox does not bring it on iOS)")

      if (line ~ /\.onHover[ \t]*[({]/ || line ~ /\.onContinuousHover/) hit("adapt", "hover (needs a touch alternative)")
      if (line ~ /\.(keyboardShortcut|onKeyPress)[ \t]*\(/) hit("adapt", "keyboard (no keyboard on most iPhones)")
      if (line ~ /\.help[ \t]*\(/) hit("adapt", ".help tooltip (not shown on touch)")
      if (line ~ /(^|[^A-Za-z0-9_])(CommandMenu|CommandGroup)([^A-Za-z0-9_]|$)/ || line ~ /\.commands[ \t]*\{/) hit("adapt", "menu bar commands")
      if (line ~ /\.contextMenu[ \t]*[({]/) hit("adapt", "context menu (long press on iOS)")
      if (line ~ /\.(onDrop|dropDestination|draggable|onDrag)[ \t]*\(/) hit("adapt", "drag and drop")
      if (line ~ /\.popover[ \t]*\(/) hit("adapt", "popover (a sheet on iPhone)")
      if (line ~ /\.fileImporter[ \t]*\(|\.fileExporter[ \t]*\(/) hit("adapt", "file access (document picker on iOS)")
      if (line ~ /(^|[^A-Za-z0-9_])DocumentGroup[ \t]*\(/) hit("adapt", "document app (a document browser on iOS)")
      if (line ~ /(^|[^A-Za-z0-9_])openWindow([^A-Za-z0-9_]|$)/) hit("adapt", "several windows (one on iPhone, scenes on iPad)")
      if (line ~ /(^|[^A-Za-z0-9_.])Table[ \t]*[({<]/) hit("adapt", "Table (one column in compact width)")
    }'
  )
}

modules() { # "<module><TAB><source files>" for every module, sorted
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
      END { for (m in files) printf "%s\t%d\n", m, files[m] }' | LC_ALL=C sort
}

# The copy leaves out files that look like secrets BY NAME (.env*, Secrets*, keys, certificates,
# provisioning profiles, .netrc). It is not a sandbox: a secret under another name is copied, and
# the build on the copy runs the project's scripts with the user's permissions.
make_copy() { # sets work and copy: a copy of the project with no .git, build output or secrets
  work="$(mktemp -d "${TMPDIR:-/tmp}/swift-harness-port.XXXXXX")" || exit 1
  work="$(cd "$work" && pwd -P)" # the physical path: the compiler prints it, not a link
  copy="$work/copy"
  if [ "$keep" != true ]; then trap 'rm -rf "$work"' EXIT; fi
  mkdir -p "$copy"
  # --copy-unsafe-links: a link that points outside the project becomes a copy of its file, so the
  # copy builds as the project does.
  rsync -a --copy-unsafe-links --exclude .git --exclude .build --exclude DerivedData --exclude Pods --exclude Carthage \
    --exclude '.env*' --exclude 'Secrets*' --exclude '*.p12' --exclude '*.pem' --exclude '*.mobileprovision' \
    --exclude '*.p8' --exclude '*.key' --exclude '.netrc' --exclude '*.keychain' --exclude '*.keychain-db' \
    --exclude 'id_rsa*' --exclude 'id_ed25519*' \
    "$@" "$root/" "$copy/" 2>"$work/rsync.err"
  case $? in
    0) ;;
    23 | 24) # some files could not be read or vanished: a broken link, a file being written
      printf 'Note: not copied (the build sees the rest): %s\n' \
        "$(sed -n -E 's/^rsync(\([0-9]+\))?: (error|warning): (.+): (stat|readlink|open|link_stat|opendir)[^:]*:.*/\3/p' "$work/rsync.err" |
          SH_ROOT_P="$root/" awk '{ if (index($0, ENVIRON["SH_ROOT_P"]) == 1) $0 = substr($0, length(ENVIRON["SH_ROOT_P"]) + 1); print }' | head -3 | paste -sd';' - | sed 's/;/; /g')" ;;
    *) printf 'porting: could not copy the project: %s\n' "$(head -n 1 "$work/rsync.err")"; exit 1 ;;
  esac
}

first_errors() { # $1 compiler output -> "module<TAB>file:line:col: message" for the first 3, then "count<TAB>N"
  # error lines "path:line:col: error: message", the path read as the module that holds the file.
  # Also "path:line:col: fatal error: message" (a missing C header) and the new build system's
  # "error: path:line:col message".
  # Colors and terminal hyperlinks (OSC 8, ending in ESC \ or BEL) are removed; a link keeps its text.
  printf '%s\n' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b[]]8;[^;\x1b\x07]*;[^\x1b\x07]*(\x1b[\\]|\x07)//g' | awk -v copy="$copy/" -v copy2="${copy#/private}/" '
    /^\/.*:[0-9]+:[0-9]+: fatal error: / { sub(/: fatal error: /, ": error: ") }
    /^error: \/.*:[0-9]+:[0-9]+ / { l = substr($0, 8); if (match(l, /:[0-9]+:[0-9]+ /)) $0 = substr(l, 1, RSTART + RLENGTH - 2) ": error: " substr(l, RSTART + RLENGTH) }
    /^\/.*:[0-9]+:[0-9]+: error: / {
      f = $0; sub(/:[0-9]+:[0-9]+: error: .*/, "", f); line = $0; sub(/^[^:]*:/, "", line)
      loc = line; sub(/: error: .*/, "", loc); msg = line; sub(/^[0-9]+:[0-9]+: error: /, "", msg)
      # xcodebuild may print the copy without /private (TMPDIR is a link to it).
      rel = f; if (index(rel, copy) == 1) rel = substr(rel, length(copy) + 1); else if (index(rel, copy2) == 1) rel = substr(rel, length(copy2) + 1)
      k = rel ":" loc ": " msg
      if (!(k in seen)) { seen[k] = 1; n++; if (n <= 3) { mod = "-"; if (match(rel, /^Sources\/[^\/]+\//)) mod = substr(rel, 9, RLENGTH - 9); printf "%s\t%s\n", mod, k } }
    }
    END { print "count\t" n + 0 }'
}

# Xcode projects (#171): sets xc_args (-workspace X or -project X) and xc_name. $1 is --project
# (a .xcworkspace or .xcodeproj at the root), else the one workspace at the root, else the one
# project. Returns 1 when there is none.
xcode_container() {
  xc_args=(); xc_name=""
  if [ -n "${1:-}" ]; then
    case "$1" in */* | .*) usage ;; *.xcworkspace) xc_args=(-workspace "$1") ;; *.xcodeproj) xc_args=(-project "$1") ;; *) usage ;; esac
    [ -d "$root/$1" ] || { printf 'porting: no %s at %s.\n' "$1" "$root"; exit 1; }
    xc_name="$1"; return 0
  fi
  local ws=() pj=() f
  for f in "$root"/*.xcworkspace; do [ -d "$f" ] && ws+=("$(basename "$f")"); done
  for f in "$root"/*.xcodeproj; do [ -d "$f" ] && pj+=("$(basename "$f")"); done
  if [ ${#ws[@]} -eq 1 ]; then xc_args=(-workspace "${ws[0]}"); xc_name="${ws[0]}"
  elif [ ${#ws[@]} -eq 0 ] && [ ${#pj[@]} -eq 1 ]; then xc_args=(-project "${pj[0]}"); xc_name="${pj[0]}"
  elif [ ${#ws[@]} -eq 0 ] && [ ${#pj[@]} -eq 0 ]; then return 1
  else
    printf 'porting: several Xcode workspaces or projects at %s (%s): name one with --project NAME.\n' "$root" \
      "$(printf '%s\n' ${ws[@]+"${ws[@]}"} ${pj[@]+"${pj[@]}"} | paste -sd, - | sed 's/,/, /g')"
    exit 1
  fi
}
# A build or test that failed because the scheme has no iOS destination: a Mac-only scheme, not a
# compile error.
no_ios_destination() { grep -qE 'Unable to find a destination matching|Supported platforms for the buildables in the current scheme is empty|does not support the iOS Simulator|no iOS Simulator destination' <<<"$1"; }

pick_simulator() { # $1 --device or empty; sets udid name version state, or exits
  local sim
  sim="$(xcrun simctl list devices available --json 2>/dev/null | jq -r --arg want "$1" '
    [.devices // {} | to_entries[]
      | select(.key | test("SimRuntime\\.iOS-[0-9]+-[0-9]+$"))
      | (.key | capture("iOS-(?<a>[0-9]+)-(?<b>[0-9]+)$")) as $v
      | {v: [($v.a | tonumber), ($v.b | tonumber)], ver: "\($v.a).\($v.b)", d: .value[]}
      | select(.d.isAvailable != false)
      | select(if $want == "" then (.d.name | startswith("iPhone")) else .d.name == $want end)]
    | sort_by(.v | map(-.)) | .[0] // empty | [.d.udid, .d.name, .ver, .d.state] | @tsv' 2>/dev/null)"
  if [ -z "$sim" ]; then
    if [ -n "$1" ]; then printf 'porting: no available iOS simulator called "%s" (xcrun simctl list devices available).\n' "$1"
    else printf 'porting: no iPhone simulator available (Xcode > Settings > Components installs an iOS runtime).\n'; fi
    exit 1
  fi
  IFS=$'\t' read -r udid name version state <<<"$sim"
}

report_tests() { # $1 xcodebuild output, $2 result bundle: counts and first failures, or why there are none
  # Returns 0 only when tests ran and none failed.
  local out="$1" bundle="$2" summary errs n rc=0
  summary=""
  [ -d "$bundle" ] && summary="$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null)"
  if [ "$(jq -r '.totalTestCount // 0' <<<"${summary:-{\}}" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    [ "$(jq -r '.failedTests // 0' <<<"$summary")" = 0 ] || rc=1
    jq -r '"- \(.totalTestCount) test(s): \(.passedTests // 0) passed, \(.failedTests // 0) failed, \(.skippedTests // 0) skipped" + (if (.expectedFailures // 0) > 0 then ", \(.expectedFailures) expected failure(s)" else "" end) + ".",
      (if ((.testFailures // []) | length) > 0 then "Failures\(if (.testFailures | length) > 5 then " (first 5)" else "" end):" else empty end),
      ((.testFailures // [])[:5][] | "    \(.targetName // "?")/\(.testName // "?"): \((.failureText // "") | gsub("\\s+"; " ") | .[:200])")' <<<"$summary"
  elif [ -d "$bundle" ] && [ -z "$summary" ]; then
    rc=1
    printf -- '- the result bundle could not be read (xcresulttool get test-results needs Xcode 16 or later); xcodebuild said: %s\n' \
      "$(printf '%s\n' "$out" | grep -m1 -E '\*\* TEST (SUCCEEDED|FAILED) \*\*' || printf 'nothing about the tests')"
  elif no_ios_destination "$out"; then
    rc=1
    printf -- '- not run: the scheme has no iOS destination yet (its targets are macOS only)\n'
  else
    rc=1
    errs="$(first_errors "$out")"
    n="$(printf '%s\n' "$errs" | awk -F'\t' '$1 == "count" { print $2 }')"
    if [ "${n:-0}" -gt 0 ]; then
      printf -- '- the tests did not build: %s error(s)\n' "$n"
      printf '%s\n' "$errs" | awk -F'\t' '$1 != "count" { printf "    %s\n", $2 }'
    else
      printf -- '- the tests did not run: %s\n' "$(printf '%s\n' "$out" | sed $'s/\x1b\\[[0-9;]*m//g' | grep -m1 'error:' || printf '%s\n' "$out" | tail -n 1)" | cut -c1-240
    fi
  fi
  return "$rc"
}

test_check() {
  local targets=() device="" keep=false t schemes=() project=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || usage; targets+=("$2"); shift 2 ;;
      --device) [ $# -ge 2 ] || usage; device="$2"; shift 2 ;;
      --scheme) [ $# -ge 2 ] && [ -n "$2" ] || usage; schemes+=("$2"); shift 2 ;;
      --project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
      --keep) keep=true; shift ;;
      *) usage ;;
    esac
  done
  for t in ${targets[@]+"${targets[@]}"}; do [[ "$t" =~ ^[A-Za-z0-9_.-]+$ ]] || usage; done
  local tool
  for tool in xcodebuild xcrun jq; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'porting: %s is needed to run tests on the iOS Simulator.\n' "$tool"; exit 1; }
  done
  if [ -n "$project" ] || [ ${#schemes[@]} -gt 0 ] || [ ! -f "$root/Package.swift" ]; then
    [ ${#targets[@]} -eq 0 ] || { printf 'porting: --target names test targets of a package; in an Xcode project name the test scheme with --scheme.\n'; exit 2; }
    xcode_container "$project" || { printf 'porting: no Package.swift and no Xcode project or workspace at %s.\n' "$root"; exit 1; }
    [ ${#schemes[@]} -gt 0 ] || { printf 'porting: name the test scheme of %s with --scheme (xcodebuild -list shows them).\n' "$xc_name"; exit 1; }
    local udid name version state s out result=0
    pick_simulator "$device"
    make_copy
    printf 'Tests on the iOS Simulator (%s, iOS %s) on a copy of %s, %s:\n' "$name" "$version" "$root" "$xc_name"
    for s in "${schemes[@]}"; do
      printf 'Scheme %s:\n' "$s"
      out="$(cd "$copy" && xcodebuild test "${xc_args[@]}" -scheme "$s" -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$work/dd" -resultBundlePath "$work/run-$(printf '%s' "$s" | tr -c 'A-Za-z0-9_.-' _).xcresult" CODE_SIGNING_ALLOWED=NO </dev/null 2>&1)"
      report_tests "$out" "$work/run-$(printf '%s' "$s" | tr -c 'A-Za-z0-9_.-' _).xcresult" || result=1
    done
    [ "$state" != Shutdown ] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    printf 'This ran the schemes'"'"' tests on one simulator: no UI was looked at unless a UI test did, the Mac app was not built, and a skipped test proves nothing.\n'
    [ "$keep" != true ] || printf 'Copy kept at %s\n' "$copy"
    exit "$result"
  fi
  if [ ${#targets[@]} -eq 0 ]; then
    for t in "$root"/Tests/*/; do [ -d "$t" ] && targets+=("$(basename "$t")"); done
  fi
  [ ${#targets[@]} -gt 0 ] || { printf 'porting: no test target found under Tests/. Name them with --target.\n'; exit 1; }

  # The simulator: the first iPhone of the newest iOS runtime, or the one --device names.
  local udid name version state
  pick_simulator "$device"

  # A copy without the root Xcode project or workspace, so xcodebuild opens the package, and a
  # temporary scheme in it that builds and runs only these test targets (-only-testing would still
  # build every target of the package, macOS-only ones too).
  make_copy --exclude '/*.xcodeproj' --exclude '/*.xcworkspace'
  local scheme_dir="$copy/.swiftpm/xcode/xcshareddata/xcschemes" refs entries="" testables=""
  mkdir -p "$scheme_dir"
  for t in "${targets[@]}"; do
    refs="<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"$t\" BuildableName=\"$t\" BlueprintName=\"$t\" ReferencedContainer=\"container:\"></BuildableReference>"
    entries="$entries<BuildActionEntry buildForTesting=\"YES\" buildForRunning=\"NO\" buildForProfiling=\"NO\" buildForArchiving=\"NO\" buildForAnalyzing=\"NO\">$refs</BuildActionEntry>"
    testables="$testables<TestableReference skipped=\"NO\">$refs</TestableReference>"
  done
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Scheme LastUpgradeVersion="2600" version="1.7">' \
    "<BuildAction parallelizeBuildables=\"YES\" buildImplicitDependencies=\"YES\"><BuildActionEntries>$entries</BuildActionEntries></BuildAction>" \
    "<TestAction buildConfiguration=\"Debug\" selectedDebuggerIdentifier=\"\" selectedLauncherIdentifier=\"Xcode.IDEFoundation.Launcher.PosixSpawn\" shouldUseLaunchSchemeArgsEnv=\"YES\"><Testables>$testables</Testables></TestAction>" \
    '</Scheme>' >"$scheme_dir/swift-harness-port-tests.xcscheme"

  printf 'Tests on the iOS Simulator (%s, iOS %s) on a copy of %s:\n' "$name" "$version" "$root"
  printf 'Test targets: %s\n' "$(printf '%s\n' "${targets[@]}" | paste -sd, - | sed 's/,/, /g')"
  local out
  out="$(cd "$copy" && xcodebuild test -scheme swift-harness-port-tests -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$work/dd" -resultBundlePath "$work/run.xcresult" </dev/null 2>&1)"
  local result=0
  report_tests "$out" "$work/run.xcresult" || result=1
  [ "$state" != Shutdown ] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  printf 'This ran the package'"'"'s test targets on one simulator: no UI was looked at, the Mac app was not built, and a skipped test proves nothing.\n'
  [ "$keep" != true ] || printf 'Copy kept at %s\n' "$copy"
  exit "$result"
}

build_check_xcode() { # schemes, keep, sdk_version set by build_check
  command -v xcodebuild >/dev/null 2>&1 || { printf 'porting: xcodebuild is needed to build an Xcode project for the iOS Simulator.\n'; exit 1; }
  command -v jq >/dev/null 2>&1 || { printf 'porting: jq is needed to read the schemes of an Xcode project.\n'; exit 1; }
  make_copy
  local s out status list built=0 failed=0 notios=0 errs n
  if [ ${#schemes[@]} -eq 0 ]; then
    list="$(cd "$copy" && xcodebuild -list -json "${xc_args[@]}" </dev/null 2>/dev/null)"
    while IFS= read -r s; do [ -n "$s" ] && schemes+=("$s"); done < <(jq -r '(.workspace.schemes // .project.schemes // [])[]' <<<"$list" 2>/dev/null)
    [ ${#schemes[@]} -gt 0 ] || { printf 'porting: no scheme found in %s (xcodebuild -list). Name one with --scheme.\n' "$xc_name"; exit 1; }
  fi
  printf 'Build for the iOS Simulator (generic destination, SDK %s) on a copy of %s, %s:\n' "${sdk_version:-?}" "$root" "$xc_name"
  for s in "${schemes[@]}"; do
    out="$(cd "$copy" && xcodebuild build "${xc_args[@]}" -scheme "$s" -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$work/dd" CODE_SIGNING_ALLOWED=NO </dev/null 2>&1)"; status=$?
    if [ "$status" -eq 0 ]; then printf -- '- PASS %s\n' "$s"; built=$((built + 1)); continue; fi
    if no_ios_destination "$out"; then
      printf -- '- NOT iOS %s: the scheme has no iOS destination yet (its targets are macOS only)\n' "$s"; notios=$((notios + 1)); continue
    fi
    failed=$((failed + 1))
    errs="$(first_errors "$out")"
    n="$(printf '%s\n' "$errs" | awk -F'\t' '$1 == "count" { print $2 }')"
    if [ "${n:-0}" -eq 0 ]; then
      printf -- '- FAIL %s: the build failed with no error line the scan could read: %s\n' "$s" "$(printf '%s\n' "$out" | sed $'s/\x1b\\[[0-9;]*m//g' | grep -m1 'error:' || printf '%s\n' "$out" | tail -n 1)" | cut -c1-240
      continue
    fi
    printf -- '- FAIL %s: %s error(s)\n' "$s" "$n"
    printf '%s\n' "$errs" | awk -F'\t' '$1 != "count" { printf "    %s\n", $2 }'
  done
  printf '%d built, %d failed, %d with no iOS destination. This is a build only: nothing was tested, no UI was looked at, the Mac app was not built.\n' "$built" "$failed" "$notios"
  [ "$keep" != true ] || printf 'Copy kept at %s\n' "$copy"
  [ "$failed" -eq 0 ]; exit
}

build_check() {
  local targets=() ios="" keep=false t schemes=() project=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || usage; targets+=("$2"); shift 2 ;;
      --scheme) [ $# -ge 2 ] && [ -n "$2" ] || usage; schemes+=("$2"); shift 2 ;;
      --project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
      --ios) [ $# -ge 2 ] || usage; ios="$2"; shift 2 ;;
      --keep) keep=true; shift ;;
      *) usage ;;
    esac
  done
  [[ -z "$ios" || "$ios" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage
  for t in ${targets[@]+"${targets[@]}"}; do [[ "$t" =~ ^[A-Za-z0-9_.-]+$ ]] || usage; done
  if ! command -v swift >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
    printf 'porting: swift and xcrun are needed to build for the iOS Simulator.\n'; exit 1
  fi
  local sdk sdk_version
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"
  [ -n "$sdk" ] && [ -d "$sdk" ] || { printf 'porting: no iOS Simulator SDK (install the iOS platform in Xcode).\n'; exit 1; }
  sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)"
  [ -n "$ios" ] || ios="${sdk_version%%.*}.0"
  if [ -n "$project" ] || [ ${#schemes[@]} -gt 0 ] || [ ! -f "$root/Package.swift" ]; then
    [ ${#targets[@]} -eq 0 ] || { printf 'porting: --target names targets of a package; in an Xcode project name schemes with --scheme.\n'; exit 2; }
    xcode_container "$project" || { printf 'porting: no Package.swift and no Xcode project or workspace at %s.\n' "$root"; exit 1; }
    build_check_xcode
  fi
  if [ ${#targets[@]} -eq 0 ]; then
    for t in "$root"/Sources/*/; do [ -d "$t" ] && targets+=("$(basename "$t")"); done
  fi
  [ ${#targets[@]} -gt 0 ] || { printf 'porting: no target found under Sources/. Name them with --target.\n'; exit 1; }

  local arch out status n
  make_copy
  arch="$(uname -m)"; [ "$arch" = arm64 ] || arch=x86_64
  printf 'Build for the iOS Simulator (%s, iOS %s, SDK %s) on a copy of %s:\n' "$arch" "$ios" "${sdk_version:-?}" "$root"
  local failed=0 passed=0 dep_errors=false
  for t in "${targets[@]}"; do
    out="$(cd "$copy" && swift build --scratch-path "$work/build" --target "$t" --triple "$arch-apple-ios$ios-simulator" --sdk "$sdk" </dev/null 2>&1)"; status=$?
    if [ "$status" -eq 0 ]; then printf -- '- PASS %s\n' "$t"; passed=$((passed + 1)); continue; fi
    failed=$((failed + 1))
    errs="$(first_errors "$out")"
    n="$(printf '%s\n' "$errs" | awk -F'\t' '$1 == "count" { print $2 }')"
    if [ "${n:-0}" -eq 0 ]; then
      printf -- '- FAIL %s: the build failed with no error line the scan could read: %s\n' "$t" "$(printf '%s\n' "$out" | tail -n 1 | cut -c1-160)"
      continue
    fi
    printf -- '- FAIL %s: %s error(s)\n' "$t" "$n"
    printf '%s\n' "$errs" | awk -F'\t' -v t="$t" '$1 != "count" && $1 != "-" && $1 != t { f = 1 } END { exit !f }' && dep_errors=true
    printf '%s\n' "$errs" | awk -F'\t' -v t="$t" '$1 != "count" { printf "    %s%s\n", $2, ($1 != "-" && $1 != t ? "  (in " $1 ", a dependency)" : "") }'
  done
  if [ "$dep_errors" = true ]; then printf 'A target behind a failing dependency shows the dependency'"'"'s errors; its own come once the dependency builds.\n'; fi
  printf '%d built, %d failed. This is a build only: nothing was tested, no UI was looked at, the Mac app was not built.\n' "$passed" "$failed"
  [ "$keep" != true ] || printf 'Copy kept at %s\n' "$copy"
  [ "$failed" -eq 0 ]; exit
}

# ---------- ratchet (#73) ----------
# The ratchet file lists the modules already ported, as scan names them, and the macOS-only
# uses accepted in them, counted per file and signal (lines move with every edit, counts do
# not). Tab-separated, # starts a comment:
#   module    <module>
#   accepted  <module>  <file>  <signal>  <count>
ratchet_file() {
  local rel
  rel="$(jq -r '.porting.ratchet // empty' "$root/.claude/swift-harness.json" 2>/dev/null)"
  rel="${rel:-docs/PORTING_RATCHET.tsv}"
  printf '%s' "${rel#./}"
}
module_dir() { printf '%s' "${1// › //}"; } # "pkg › Sources/T" -> pkg/Sources/T

ratchet() {
  local record=false mods=() m rel file
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) record=true; shift ;;
      --module) [ $# -ge 2 ] && [ -n "$2" ] || usage; mods+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$record" = true ] || [ ${#mods[@]} -eq 0 ] || usage
  rel="$(ratchet_file)"
  file="$root/$rel"
  local listed
  listed="$(awk -F'\t' '$1 == "module" && $2 != "" { print $2 }' "$file" 2>/dev/null)"

  if [ "$record" = true ]; then
    local known
    known="$(modules)"
    for m in ${mods[@]+"${mods[@]}"}; do
      case "$m" in . | /* | *..*) printf 'porting: %s is not a module folder.\n' "$m"; exit 2 ;; esac
      [ -n "$(SH_M="$m" awk -F'\t' '$1 == ENVIRON["SH_M"]' <<<"$known")" ] || { printf 'porting: no module %s. Name it as porting.sh summary does: %s\n' "$m" "$(cut -f1 <<<"$known" | grep -vxF . | paste -sd, - | sed 's/,/, /g')"; exit 2; }
      listed="$(printf '%s\n%s' "$listed" "$m")"
    done
    listed="$(printf '%s\n' "$listed" | awk 'NF && !seen[$0]++')"
    [ -n "$listed" ] || { printf 'porting: no module to record. Name one with --module, as porting.sh summary names it.\n'; exit 2; }
    local dirs hits
    dirs="$(printf '%s\n' "$listed" | while IFS= read -r m; do module_dir "$m"; printf '\n'; done)"
    hits="$(scan "$dirs" | SH_MODS="$listed" awk -F'\t' 'BEGIN { n = split(ENVIRON["SH_MODS"], M, "\n"); for (i = 1; i <= n; i++) want[M[i]] = 1 }
      $1 == "blocks" && ($2 in want) { f = $3; sub(/:[0-9]+$/, "", f); c[$2 "\t" f "\t" $4]++ }
      END { for (k in c) print "accepted\t" k "\t" c[k] }' | LC_ALL=C sort)"
    mkdir -p "$(dirname "$file")" || exit 1
    {
      printf '# swift-harness porting ratchet (#73): these modules build for iOS and must keep building.\n'
      printf '# A new macOS-only use in one of them fails the end-of-turn check. Accepted uses are counted\n'
      printf '# per file and signal. Written by porting.sh ratchet --record, with the user'"'"'s yes.\n'
      printf '%s\n' "$listed" | sed 's/^/module\t/'
      [ -z "$hits" ] || printf '%s\n' "$hits"
    } >"$file.tmp" && mv "$file.tmp" "$file"
    printf 'Porting ratchet (%s): %d module(s), %d macOS-only use(s) accepted.\n' "$rel" "$(printf '%s\n' "$listed" | grep -c .)" "$(printf '%s\n' "$hits" | awk -F'\t' 'NF { n += $5 } END { print n + 0 }')"
    [ -z "$hits" ] || printf '%s\n' "$hits" | awk -F'\t' '{ printf "- accepted: %s: %s (%d)\n", $3, $4, $5 }'
    exit 0
  fi

  # Check: exit 0 with no ratchet file or nothing new, 1 with a new macOS-only use.
  [ -f "$file" ] || exit 0
  [ -n "$listed" ] || exit 0
  local dirs report
  dirs="$(printf '%s\n' "$listed" | while IFS= read -r m; do module_dir "$m"; printf '\n'; done)"
  report="$(scan "$dirs" | SH_MODS="$listed" SH_RF="$file" awk -F'\t' '
    BEGIN {
      n = split(ENVIRON["SH_MODS"], M, "\n"); for (i = 1; i <= n; i++) want[M[i]] = 1
      rf = ENVIRON["SH_RF"]; while ((getline l < rf) > 0) { split(l, a, "\t"); if (a[1] == "accepted") ok[a[2] "\t" a[3] "\t" a[4]] = a[5] + 0 }
    }
    $1 == "blocks" && ($2 in want) { f = $3; sub(/:[0-9]+$/, "", f); k = $2 "\t" f "\t" $4; c[k]++; at[k] = at[k] (at[k] == "" ? "" : ", ") $3 }
    END {
      for (k in c) {
        has = (k in ok) # before ok[k] is read: reading an element creates it
        if (c[k] <= ok[k] + 0) continue
        split(k, p, "\t")
        printf "- %s: %s (in %s, ported to iOS; %s)\n", at[k], p[3], p[1], (has ? ok[k] " accepted here, " c[k] " now" : "none accepted here")
      }
    }' | LC_ALL=C sort)"
  [ -n "$report" ] || exit 0
  printf 'Porting ratchet (%s): new macOS-only code in a module that builds for iOS:\n%s\n' "$rel" "$report"
  printf 'Put it inside #if os(macOS), or behind a protocol with a macOS and an iOS implementation, so the module keeps building for iOS. If the user wants to keep it as it is, they accept it with porting.sh ratchet --record; do not record it yourself to make this check pass.\n'
  exit 1
}

if [ "$mode" = ratchet ]; then
  ratchet "$@"
fi
if [ "$mode" = build-check ]; then
  build_check "$@"
fi
if [ "$mode" = test-check ]; then
  test_check "$@"
fi

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
modules |
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
