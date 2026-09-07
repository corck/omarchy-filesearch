#!/bin/bash
# List one directory, emitting exactly the rows search.sh emits:
#   kind \t name \t dir \t path \t mtime \t size
#
# Same shape on purpose: the preview pane reuses the row delegate, so a
# folder listing and a search result are interchangeable to the QML side.

set -o pipefail

LIMIT=${LIMIT:-500}
dir="${1:-}"
[[ -n $dir && -d $dir ]] || exit 0

# Trailing slash would turn "/foo/" into a path of "/foo//bar".
[[ $dir == / ]] || dir="${dir%/}"

emit() {
  local kind="$1"
  shift
  # One find per kind keeps directories grouped ahead of files without
  # having to sort on a synthetic key.
  find "$dir" -maxdepth 1 -mindepth 1 "$@" -printf '%f\t%Ts\t%s\n' 2>/dev/null |
    sort -t$'\t' -k1,1f |
    while IFS=$'\t' read -r name mtime size; do
      [[ -n $name ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$name" "${dir/#$HOME/\~}" "$dir/$name" "$mtime" "$size"
    done
}

{
  emit dir -type d
  emit file ! -type d
} | head -n "$LIMIT"
