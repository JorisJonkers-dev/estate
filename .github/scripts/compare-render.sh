#!/usr/bin/env bash
# compare-render.sh <published> <replayed>: compare two rendered trees byte
# for byte, and name every path where they differ.
#
# <published> is a Rendered artifact as `oras pull` unpacks it; <replayed> is
# the same Project's share of a render made again (replay.sh). Each file is
# compared by its bytes alone: a file's mode, owner and time come from the tar
# layer `oras push` packs, never from the render, and Flux applies a file's
# contents only. Empty directories are not compared either: a render writes
# files and nothing else.
#
# Prints one line per differing path, sorted by path, and exits 1 if there is
# any:
#   differs: <path>              in both trees, with other bytes
#   only in published: <path>    the artifact holds a file the replay did not render
#   only in replayed: <path>     the replay rendered a file the artifact lacks
#   not a regular file: <path>   a symlink, a device or the like, in either tree
# Exits 0 when both trees hold the same files with the same bytes, and 2 when
# it is called wrongly or a tree holds a path it cannot list.
#
# Its fixtures run with `bash .github/scripts/test-compare-render.sh`.
set -euo pipefail

usage="usage: compare-render.sh <published> <replayed>"
published="${1:?$usage}"
replayed="${2:?$usage}"
for tree in "$published" "$replayed"; do
  [ -d "$tree" ] || { echo "compare-render.sh: ${tree} is not a directory" >&2; exit 2; }
done

export LC_ALL=C
tab="$(printf '\t')"
if command -v sha256sum > /dev/null; then hasher=(sha256sum); else hasher=(shasum -a 256); fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: > "$work/report"

# list <tree> <side>: every regular file's path, and "<path>\t<sha256>" for
# each, both sorted by path; anything neither a file nor a directory goes to
# the report, never followed, since a symlink could name a file outside it.
list() {
  (
    cd "$1"
    # A path is listed one per line, and sha256sum escapes a backslash: a
    # render writes neither, so either is refused rather than misread.
    if find . -name "*"$'\n'"*" -o -name '*\\*' | grep -q .; then
      echo "compare-render.sh: $1 holds a path with a newline or a backslash" >&2
      exit 2
    fi
    find . ! -type f ! -type d | sed 's|^\./||' | while IFS= read -r path; do
      printf '%s\tnot a regular file\n' "$path"
    done >> "$work/report"
    find . -type f | sed 's|^\./||' | sort > "$work/paths.$2"
    : > "$work/hashes.$2"
    if [ -s "$work/paths.$2" ]; then
      tr '\n' '\0' < "$work/paths.$2" | xargs -0 "${hasher[@]}" \
        | sed "s|^\([0-9a-f]\{64\}\) [ *]\(.*\)\$|\2${tab}\1|" | sort -t "$tab" -k1,1 > "$work/hashes.$2"
    fi
  )
}

list "$published" published
list "$replayed" replayed

{
  comm -23 "$work/paths.published" "$work/paths.replayed" | sed "s|\$|${tab}only in published|"
  comm -13 "$work/paths.published" "$work/paths.replayed" | sed "s|\$|${tab}only in replayed|"
  join -t "$tab" "$work/hashes.published" "$work/hashes.replayed" \
    | awk -F "$tab" -v OFS="$tab" '$2 != $3 { print $1, "differs" }'
} >> "$work/report"

if [ -s "$work/report" ]; then
  sort -t "$tab" -k1,1 "$work/report" | awk -F "$tab" '{ print $2 ": " $1 }'
  exit 1
fi
