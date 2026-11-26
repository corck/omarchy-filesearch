#!/bin/bash
# Query the file name index (plocate) and the localsearch index, and emit one
# TSV row per hit:
#   kind \t name \t dir \t path \t mtime \t size
#
# The shell runs this on every (debounced) keystroke, so it stays a single
# pass: query, dedupe, drop stale index entries, truncate. Nothing is
# shell-interpreted -- terms arrive as positional args and leave as literal
# argv for plocate and localsearch.
#
# Two kinds of matching, merged:
#   - Names and paths, the way Everything does it: every term is a
#     case-insensitive substring, all terms must match. A term without a "/"
#     matches the file name; a term with one matches the full path, so a
#     pasted "/home/me/Work/project" finds that folder and what is in it.
#     plocate answers this from its database in milliseconds.
#   - Content, from localsearch's full-text index, as before.
#
# A query that is an existing path (absolute, "~/...", or a file:// URI) also
# lists that item and its current children straight off the disk, so a folder
# made after plocate's nightly updatedb still shows up.

set -o pipefail

LIMIT=${LIMIT:-200}        # rows emitted in total
NAME_LIMIT=${NAME_LIMIT:-150} # of which at most this many from the name index
CONTENT_LIMIT=${CONTENT_LIMIT:-40} # per localsearch pass
raw="${1:-}"
[[ -n $raw ]] || exit 0

# A leading prefix narrows the resource type; without one we search names,
# paths and content and merge.
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

# A path copied out of a terminal or a file manager often comes quoted, or as
# a file:// URI. Either way it means the path.
if [[ $query =~ ^\'(.*)\'$ || $query =~ ^\"(.*)\"$ ]]; then
  query=${BASH_REMATCH[1]}
fi
if [[ $query == file://* ]]; then
  encoded=${query#file://}
  encoded=${encoded//\\/\\\\}
  printf -v query '%b' "${encoded//%/\\x}"
fi
if [[ $query == "~" || $query == "~/"* ]]; then
  query="$HOME${query#\~}"
fi

[[ ${#query} -ge 2 ]] || exit 0

# An existing absolute path is one term, spaces and all; anything else splits
# on whitespace into terms that must all match.
exact=""
candidate=$query
[[ $candidate == / ]] || candidate=${candidate%/}
if [[ $candidate == /* && -e $candidate ]]; then
  exact=$candidate
  terms=("$candidate")
else
  read -r -a terms <<<"$query"
fi
[[ ${#terms[@]} -gt 0 ]] || exit 0

pathish=0
name_terms=()
for t in "${terms[@]}"; do
  if [[ $t == */* ]]; then
    pathish=1
  else
    name_terms+=("${t,,}")
  fi
done

# Dependency and cache trees hold most of the name index (node_modules alone
# is well over half of it) and are never what a name search is looking for.
# They stay out unless the query itself reaches into one.
junk_re='/(node_modules|\.git|\.cache|__pycache__|\.venv|\.mypy_cache|\.pytest_cache|\.npm|\.Trash-[0-9]+|\.local/share/Trash|go/pkg/mod|\.cargo/registry|\.rustup)(/|$)'
filter_junk=1
[[ ${query,,} =~ (node_modules|\.git|\.cache|__pycache__|\.venv|_cache|\.npm|trash|pkg/mod|\.cargo|\.rustup) ]] && filter_junk=0

drop_junk() {
  if ((filter_junk)); then
    grep -zvE -- "$junk_re"
  else
    cat
  fi
}

# Everything-style name and path matches, NUL-delimited. plocate requires every
# pattern to match. Without a "/" in any term it can match the name alone (-b);
# with one it matches full paths, and the plain terms are then checked against
# the name here, so "work/ invoice" means a file named *invoice* somewhere
# under a */work/* path. A term holding a glob character is a glob to plocate
# and is left to it.
name_hits() {
  command -v plocate >/dev/null || return 0
  # A pasted folder whose own listing already fills the cap leaves no room
  # for deeper matches, and a path like ~ matches millions of them.
  if [[ -n $exact && -d $exact ]]; then
    local listed
    listed=$(find "$exact" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | head -z -n "$NAME_LIMIT" | tr -cd '\0' | wc -c)
    ((listed >= NAME_LIMIT)) && return 0
  fi
  if ((!pathish)); then
    timeout 5 plocate -i -b -0 -- "${terms[@]}" 2>/dev/null | drop_junk
  else
    timeout 5 plocate -i -0 -- "${terms[@]}" 2>/dev/null | drop_junk | names_match
  fi | keep_type | head -z -n "$name_raw"
}

# The plain terms of a path query, checked against the name alone.
names_match() {
  if ((${#name_terms[@]} == 0)); then
    cat
    return
  fi
  local IFS=$'\037'
  gawk -v RS='\0' -v ORS='\0' -v names="${name_terms[*]}" '
    BEGIN { n = split(names, want, "\037") }
    {
      base = $0; sub(/.*\//, "", base); base = tolower(base)
      for (i = 1; i <= n; i++)
        if (want[i] !~ /[*?[]/ && index(base, want[i]) == 0) next
      print
    }'
}

# The type check is cheap here and costly in the row loop below, which stats
# every candidate, so the name stream is narrowed before it is cut. A folder
# cannot be told from its name, so o: asks perl, which tests -d in a fraction
# of the time bash takes; without perl the row loop does it, reading further.
keep_type() {
  if [[ -n $ext_filter ]]; then
    grep -zEi -- "\.($ext_filter)$"
  elif [[ $mode == folders ]] && command -v perl >/dev/null; then
    perl -0 -ne 'chomp; print "$_\0" if -d'
  else
    cat
  fi
}

# localsearch hands back percent-encoded URIs, one per line. A newline in a
# name arrives as %0A, so the line framing is unambiguous; decoding to a
# NUL-delimited path keeps it that way downstream.
content_hits() {
  timeout 5 localsearch search "$@" --limit "$CONTENT_LIMIT" -- "${terms[@]}" 2>/dev/null |
    while IFS= read -r uri; do
      [[ $uri == file://* ]] || continue
      # Percent-decode via printf %b. Backslashes are doubled first so a
      # literal one in a filename is not read as the start of an escape.
      local encoded=${uri#file://} path
      encoded=${encoded//\\/\\\\}
      printf -v path '%b' "${encoded//%/\\x}"
      printf '%s\0' "$path"
    done
}

# The pasted path itself, then what is in it right now.
exact_hits() {
  [[ -n $exact ]] || return 0
  printf '%s\0' "$exact"
  [[ -d $exact ]] && find "$exact" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | head -z -n "$NAME_LIMIT"
}

# --images and --documents match what the extractor pulled out of a file --
# an image's dc:title, a document's text -- and never its filename. So those
# modes also take the name pass, and keep only rows whose extension fits.
ext_filter=""
case "$mode" in
images) ext_filter="png|jpg|jpeg|gif|webp|svg|bmp|tif|tiff|heic|avif" ;;
documents) ext_filter="pdf|doc|docx|odt|rtf|txt|md|xls|xlsx|ods|csv|ppt|pptx|odp|epub" ;;
esac

# Raw name candidates read before giving up: room for stale index entries and,
# for o:, for the files among the folders.
name_raw=$((NAME_LIMIT * 2))
[[ $mode == folders ]] && ! command -v perl >/dev/null && name_raw=5000

# Each source is tagged with the cap it is held to: N for the name index
# (and the live listing), C for localsearch, which is capped by --limit.
# localsearch only ever sees words, so a path query skips it.
collect() {
  exact_hits | sed -z 's/^/N/'
  name_hits | sed -z 's/^/N/'
  ((pathish)) && return 0
  case "$mode" in
  files) content_hits --files ;;
  folders) content_hits --folders ;;
  documents)
    content_hits --documents
    content_hits --files
    ;;
  images)
    content_hits --images
    content_hits --files
    ;;
  *)
    content_hits --files
    content_hits
    ;;
  esac | sed -z 's/^/C/'
}

paths=()
kinds=()
declare -A seen
names_kept=0

# Process substitution rather than a pipe: the loop has to run in this shell
# so the arrays survive it and the whole result set can be stat'd in one go.
while IFS= read -r -d '' tagged; do
  source=${tagged:0:1}
  path=${tagged:1}

  [[ $path == /* ]] || continue
  [[ -z ${seen[$path]} ]] || continue

  if [[ $source == N ]]; then
    ((names_kept < NAME_LIMIT)) || continue
  fi

  # The index outlives the files it points at; a deleted file is a stale row.
  [[ -e $path ]] || continue

  # A tab or a newline in a filename is legal on Linux and would be emitted
  # into the middle of this row, shifting every later column: the path column
  # would then hold the parent directory, and the overlay hands that column
  # to gio trash. A row that cannot be represented is dropped, not guessed.
  [[ $path != *$'\t'* && $path != *$'\n'* ]] || continue

  is_dir=0
  [[ -d $path ]] && is_dir=1

  # A typed mode keeps only that type. Directories stay out of it -- a folder
  # is not an image, and "i:" asked for images. The pasted path itself always
  # stays: it is what was asked for.
  if [[ $path != "$exact" ]]; then
    if [[ $mode == folders ]]; then
      ((is_dir)) || continue
    elif [[ -n $ext_filter ]]; then
      lower=${path,,}
      [[ $lower =~ \.($ext_filter)$ ]] || continue
    fi
  fi

  seen[$path]=1
  [[ $source == N ]] && ((names_kept++))
  paths+=("$path")
  if ((is_dir)); then kinds+=("dir"); else kinds+=("file"); fi

  ((${#paths[@]} >= LIMIT)) && break
done < <(collect)

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
  [[ -n $name ]] || name="/"
  [[ -n $dir ]] || dir="/"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${kinds[i]}" "$name" "${dir/#$HOME/\~}" "$path" \
    "${mtime_of[$path]:-0}" "${size_of[$path]:-0}"
done
