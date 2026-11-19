#!/bin/bash
# Architecture contracts (#13): compare the real dependency graph of each SwiftPM package
# listed in docs/architecture-contracts.json with the dependencies the contract allows.
#
# The graph comes from `swift package dump-package` (JSON), with no parsing of Swift source.
# It evaluates Package.swift, which is code from the repository: the hooks call this script
# only once the user has approved the verify command, whose build evaluates it anyway.
#
# Usage: contracts.sh [--validate] <project root>
# Exit 0: no contract, or every package matches it (notes may be printed).
# Exit 1: the contract is invalid, a manifest cannot be read, or a dependency is not allowed.
# --validate checks only the contract file and its package folders, without running any
# manifest, and prints a one-line summary (for doctor.sh).

set -u

CONTRACT_FILE="docs/architecture-contracts.json"
validate=false
[ "${1:-}" = "--validate" ] && { validate=true; shift; }
root="${1:?usage: contracts.sh [--validate] <project root>}"
contract="$root/$CONTRACT_FILE"
[ -f "$contract" ] || exit 0

header() { printf 'Architecture contracts (%s): %s\n' "$CONTRACT_FILE" "$1"; }
invalid() {
  header "the contract is invalid: $1 Fix it, or ask the user."
  exit 1
}

jq empty "$contract" >/dev/null 2>&1 || invalid "it is not valid JSON."
[ "$(jq -r '.version' "$contract")" = 1 ] || invalid '"version" must be 1.'
jq -e '.packages | type == "object"' "$contract" >/dev/null ||
  invalid '"packages" must be an object: {"<package folder>": {"<target>": ["<dependency>", ...]}}.'
bad="$(jq -r '.packages | to_entries[]
  | select((.value | type) != "object"
      or (.value | to_entries | any(.value | if type != "array" then true else any(type != "string") end)))
  | .key' "$contract" | head -1)"
[ -z "$bad" ] || invalid "in package \"$bad\", every target needs a list of names, such as \"App\": [\"Domain\"]."
if [ "$validate" = true ]; then
  missing=""
  while IFS= read -r -d '' pkg; do
    [ -f "$root/$pkg/Package.swift" ] || missing="$missing${missing:+, }$pkg"
  done < <(jq -j '.packages | keys[] | . + "\u0000"' "$contract")
  [ -z "$missing" ] || invalid "no Package.swift in: $missing. Fix the package paths."
  jq -r '"\(.packages | length) package(s), \([.packages[] | keys[]] | length) target(s)"' "$contract"
  exit 0
fi
command -v swift >/dev/null 2>&1 || { header "swift not found, so the dependency graph could not be read."; exit 1; }

# Dependencies are named as in Package.swift: a local target by its name, a product of
# another package as "<package>/<product>". Test targets are checked only when listed.
# Prints "V<TAB>message" for a violation and "N<TAB>message" for a note.
graph_check='
  (.targets | map(.name)) as $names
  | ([ .targets[]
      | select(.type != "test" or $c[.name] != null)
      | .name as $t
      | if $c[$t] == null then
          "V\t\($label): target \"\($t)\" is not in the contract."
        else
          .dependencies[]
          | (if .byName then .byName[0]
             elif .target then .target[0]
             elif .product then (if .product[1] then "\(.product[1])/\(.product[0])" else .product[0] end)
             else empty end) as $d
          | select($c[$t] | any(. == $d) | not)
          | "V\t\($label): target \"\($t)\" depends on \"\($d)\", which the contract does not allow."
        end ] | unique[]),
    ($c | keys[] | select(. as $k | $names | any(. == $k) | not)
      | "N\t\($label): the contract lists \"\(.)\", but there is no such target.")'

violations=""
notes=""
dependency_violation=false
err="$(mktemp -t swift-harness-contracts.XXXXXX)"
while IFS= read -r -d '' pkg; do
  dir="$root/$pkg"
  label="$pkg/Package.swift"
  [ "$pkg" = "." ] && label="Package.swift"
  if [ ! -f "$dir/Package.swift" ]; then
    violations="$violations- $pkg: no Package.swift in this folder. Fix the package path in the contract."$'\n'
    continue
  fi
  if ! dump="$(cd "$dir" && swift package dump-package 2>"$err")"; then
    violations="$violations- could not read $label (swift package dump-package failed):"$'\n'"$(grep -v -e '^[[:space:]]*$' -e 'compiled with:' "$err" | head -15)"$'\n'
    continue
  fi
  # A dump with no list of targets (another toolchain's format, an error printed as JSON) cannot
  # be checked: that is a failure to read, not a pass.
  if ! jq -e '(.targets | type) == "array"' <<<"$dump" >/dev/null 2>&1; then
    violations="$violations- could not read $label: swift package dump-package gave no list of targets, so its dependencies were not checked."$'\n'
    continue
  fi
  if ! result="$(jq -r --arg label "$label" --argjson c "$(jq --arg p "$pkg" '.packages[$p]' "$contract")" \
    "$graph_check" <<<"$dump" 2>"$err")"; then
    violations="$violations- could not check $label against the contract: $(head -n 1 "$err")"$'\n'
    continue
  fi
  printf '%s\n' "$result" | grep -q '^V	.*depends on' && dependency_violation=true
  violations="$violations$(printf '%s\n' "$result" | sed -n 's/^V	/- /p')"
  [ -z "$violations" ] || violations="${violations%$'\n'}"$'\n'
  notes="$notes$(printf '%s\n' "$result" | sed -n 's/^N	/- /p')"
  [ -z "$notes" ] || notes="${notes%$'\n'}"$'\n'
done < <(jq -j '.packages | keys[] | . + "\u0000"' "$contract")
rm -f "$err"

if [ -n "$violations" ]; then
  header "failed."
  printf '%s' "$violations"
  [ "$dependency_violation" = false ] ||
    printf 'Remove the dependency, or ask the user to allow it: they add it to the contract, ideally with an ADR. Do not change the contract unless the user asks.\n'
  grep -q 'is not in the contract' <<<"$violations" &&
    printf 'A new target is a module boundary decision: ask the user which dependencies it may have, then they add it to the contract.\n'
  [ -z "$notes" ] || printf 'Notes:\n%s' "$notes"
  exit 1
fi
if [ -n "$notes" ]; then
  header "passed, with notes:"
  printf '%s' "$notes"
fi
exit 0
