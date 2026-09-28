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

# Every row carries this directory, so a separator in its own name would
# corrupt all of them at once.
[[ $dir != *$'\t'* && $dir != *$'\n'* ]] || exit 0

emit() {
  local kind="$1"
  shift
  # NUL-delimited records, not newline-delimited. A newline is legal in a
  # filename, and with `-printf ...\n` such a name ends one record early and
  # starts another that find never wrote: name the file "evil<NL>victim" next
  # to a real "victim" and find's output contains a second, entirely
  # well-formed record pointing at the real victim. No amount of checking
  # after the split can tell that record from a genuine one, so the framing
  # itself has to be unambiguous. NUL is the one byte a filename cannot hold.
  #
  # The full path rather than %f, so there is a single value to vet, the same
  # one search.sh vets.
  find "$dir" -maxdepth 1 -mindepth 1 "$@" -printf '%p\t%Ts\t%s\0' 2>/dev/null |
    sort -z -t$'\t' -k1,1f |
    while IFS=$'\t' read -r -d '' path mtime size extra; do
      # Within a record the fields are still tab-separated, so a tab in the
      # name shifts them; `extra` catches that, and the timestamps confirm the
      # record is the shape find promised.
      [[ -n $path && -z $extra ]] || continue
      [[ $mtime =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] || continue

      # Same rule as search.sh: a path that cannot be written to a
      # tab-separated line is left out rather than written wrongly.
      [[ $path != *$'\t'* && $path != *$'\n'* ]] || continue

      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "${path##*/}" "${dir/#$HOME/\~}" "$path" "$mtime" "$size"
    done
}

{
  emit dir -type d
  emit file ! -type d
} | head -n "$LIMIT"
