#!/bin/bash
# Reveal a path in whatever file manager the desktop uses.
#
#   reveal.sh ShowItems   <uri> <fallback-dir>   # select the file in its folder
#   reveal.sh ShowFolders <uri> <fallback-dir>   # open the folder itself
#
# org.freedesktop.FileManager1 is the portable way to do this: Nautilus,
# Dolphin, Thunar, Nemo and PCManFM all implement it, and unlike `xdg-open` it
# can preselect an item. When nothing provides the interface we fall back to
# opening the directory, which every desktop can do.
#
# The URI must arrive percent-encoded, apostrophe included: GVariant string
# literals are single-quoted, so a raw "Mom's file.txt" aborts gdbus with a
# parse error. The caller encodes it; this script only wraps it in the array.

set -o pipefail

method="${1:-ShowItems}"
uri="${2:-}"
fallback_dir="${3:-}"

[[ -n $uri ]] || exit 1
case "$method" in
ShowItems | ShowFolders) ;;
*) exit 1 ;;
esac

if [[ $uri == *"'"* ]]; then
  echo "reveal.sh: uri must be percent-encoded (found a literal apostrophe)" >&2
  exit 1
fi

if gdbus call --session \
  --dest org.freedesktop.FileManager1 \
  --object-path /org/freedesktop/FileManager1 \
  --method "org.freedesktop.FileManager1.$method" \
  "['$uri']" "" >/dev/null 2>&1; then
  exit 0
fi

# No FileManager1 provider (or it refused): open the containing directory.
[[ -n $fallback_dir ]] || exit 1
exec setsid uwsm-app -- xdg-open "$fallback_dir"
