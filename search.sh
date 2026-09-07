#!/bin/bash
# Query localsearch and emit one TSV row per hit:
#   kind \t name \t dir \t path \t mtime \t size
#
# The shell runs this on every (debounced) keystroke, so it stays a single
# pass: query, dedupe, percent-decode, drop stale index entries, truncate.
# Nothing is shell-interpreted -- terms arrive as positional args and leave
# as literal argv for localsearch.

set -o pipefail

LIMIT=${LIMIT:-40}
raw="${1:-}"
[[ -n $raw ]] || exit 0

# A leading prefix narrows the resource type; without one we search both
# content and filenames and merge.
mode="mixed"
query="$raw"
case "$raw" in
f:*) mode="files" query="${raw#f:}" ;;
o:*) mode="folders" query="${raw#o:}" ;;
d:*) mode="documents" query="${raw#d:}" ;;
i:*) mode="images" query="${raw#i:}" ;;
esac

query="${query#"${query%%[![:space:]]*}"}"
query="${query%"${query##*[![:space:]]}"}"
[[ ${#query} -ge 2 ]] || exit 0

read -r -a terms <<<"$query"
[[ ${#terms[@]} -gt 0 ]] || exit 0

# `timeout` keeps a wedged index from hanging the overlay; a slow query just
# yields no rows and the next keystroke tries again.
run() { timeout 5 localsearch search "$@" --limit "$LIMIT" -- "${terms[@]}" 2>/dev/null; }

collect() {
  case "$mode" in
  files) run --files ;;
  folders) run --folders ;;
  documents) run --documents ;;
  images) run --images ;;
  # Filename hits first: when both match, the name match is the one the
  # user was almost certainly aiming at.
  *)
    run --files
    run
    ;;
  esac
}

paths=()
kinds=()

# Process substitution rather than a pipe: the loop has to run in this shell
# so the arrays survive it and the whole result set can be stat'd in one go.
while IFS= read -r uri; do
  [[ $uri == file://* ]] || continue

  # Percent-decode via printf %b. Backslashes are doubled first so a literal
  # one in a filename is not read as the start of an escape.
  encoded=${uri#file://}
  encoded=${encoded//\\/\\\\}
  printf -v path '%b' "${encoded//%/\\x}"

  # The index outlives the files it points at; a deleted file is a stale row.
  [[ -e $path ]] || continue

  paths+=("$path")
  if [[ -d $path ]]; then kinds+=("dir"); else kinds+=("file"); fi

  ((${#paths[@]} >= LIMIT)) && break
done < <(collect | awk '!seen[$0]++')

((${#paths[@]} > 0)) || exit 0

# One stat for the whole result set beats one fork per row. Keyed by path
# rather than by position: a file deleted between the -e test and here is
# silently skipped by stat, which would shift every later row onto the wrong
# date. Size rides along so the overlay can refuse to decode a huge image.
declare -A mtime_of size_of
while IFS=' ' read -r ts bytes file; do
  [[ -n $file ]] || continue
  mtime_of["$file"]=$ts
  size_of["$file"]=$bytes
done < <(stat -c '%Y %s %n' -- "${paths[@]}" 2>/dev/null)

for i in "${!paths[@]}"; do
  path=${paths[i]}
  name=${path##*/}
  dir=${path%/*}
  [[ -n $dir ]] || dir="/"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${kinds[i]}" "$name" "${dir/#$HOME/\~}" "$path" \
    "${mtime_of[$path]:-0}" "${size_of[$path]:-0}"
done
