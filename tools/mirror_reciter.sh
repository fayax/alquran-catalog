#!/usr/bin/env bash
# Mirrors one reciter's ayah-by-ayah files into GitHub releases, one
# release per surah: tag <reciter>-SSS, assets SSSAAA.mp3 and
# manifest-SSS.json (size and sha256 of every file).
#
# Usage: tools/mirror_reciter.sh <reciter> <source-url-template> <first> <last>
#   The template uses {surah3} and {ayah3}, for example
#   https://audio-cdn.tarteel.ai/quran/alafasy/{surah3}{ayah3}.mp3
# Needs GH_TOKEN with contents:write, gh, curl, sha256sum.
set -euo pipefail

reciter="$1"; template="$2"; first="$3"; last="$4"

# Ayahs per surah (Hafs, 6,236 in all).
counts=(0 7 286 200 176 120 165 206 75 129 109 123 111 43 52 99 128 111 110 98 135
  112 78 118 64 77 227 93 88 69 60 34 30 73 54 45 83 182 88 75 85 54 53 89 59 37
  35 38 29 18 45 60 49 62 55 78 96 29 22 24 13 14 11 11 18 12 12 30 52 52 44 28
  28 20 56 40 31 50 40 46 42 29 19 36 25 22 17 19 26 30 20 15 21 11 8 8 19 5 8 8
  11 11 8 3 9 5 4 7 3 6 3 5 4 5 6)

work="$(mktemp -d)"
repo="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

# Names and sizes of a release's assets, one "name size" per line.
# Prints nothing if the release does not exist yet.
assets() {
  local id
  if ! id=$(gh api "repos/$repo/releases/tags/$1" --jq .id 2>&1); then
    grep -q "HTTP 404" <<<"$id" && return 0
    echo "$id" >&2; return 1
  fi
  gh api --paginate "repos/$repo/releases/$id/assets?per_page=100" \
    --jq '.[] | "\(.name) \(.size)"'
}

# The workflow token allows about 1,000 API requests an hour, and every
# uploaded file costs one. When GitHub refuses a request, wait and try
# again rather than fail: the limit resets within the hour.
retry() {
  local try
  for try in $(seq 1 20); do
    "$@" && return 0
    echo "Waiting 5 minutes before trying again ($try)"
    sleep 300
  done
  echo "::error::gave up: $*"; return 1
}

for ((s = first; s <= last; s++)); do
  S=$(printf '%03d' "$s")
  tag="${reciter}-${S}"
  n=${counts[$s]}
  have=$(retry assets "$tag")
  if grep -q "^manifest-${S}.json " <<<"$have"; then
    echo "$tag: already mirrored"
    continue
  fi
  dir="$work/$S"; mkdir -p "$dir"
  echo "$tag: downloading $n ayahs"
  for ((a = 1; a <= n; a++)); do
    A=$(printf '%03d' "$a")
    url="${template//\{surah3\}/$S}"; url="${url//\{ayah3\}/$A}"
    curl -fsSL --retry 5 --retry-delay 3 -o "$dir/${S}${A}.mp3" "$url"
    # An MP3 starts with an ID3 tag or a frame sync.
    head -c 3 "$dir/${S}${A}.mp3" | grep -q 'ID3' ||
      [ "$(head -c 2 "$dir/${S}${A}.mp3" | od -An -tx1 | tr -d ' ' | cut -c1-3)" = "fff" ] || {
        echo "::error::$url is not an MP3"; exit 1; }
  done
  # Manifest: {"surah":S,"files":{"SSSAAA.mp3":{"size":..,"sha256":".."}}}
  {
    printf '{"reciter":"%s","surah":%d,"files":{' "$reciter" "$s"
    sep=""
    for f in "$dir"/*.mp3; do
      name=$(basename "$f")
      printf '%s"%s":{"size":%d,"sha256":"%s"}' "$sep" "$name" \
        "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
      sep=","
    done
    printf '}}\n'
  } > "$dir/manifest-${S}.json"
  [ "$(ls "$dir"/*.mp3 | wc -l)" -eq "$n" ] || { echo "::error::$tag count"; exit 1; }

  [ -n "$have" ] ||
    retry gh release create "$tag" --title "$reciter surah $s" \
      --notes "Ayah-by-ayah recitation, surah $s ($n ayahs). Mirrored from QUL (Quranic Universal Library) by Tarteel." \
      --latest=false
  # Skip files an earlier, interrupted run already uploaded. --clobber
  # costs extra requests, so it is only used for a file that is wrong.
  for f in "$dir"/*.mp3; do
    name=$(basename "$f")
    if grep -qx "$name $(stat -c %s "$f")" <<<"$have"; then continue; fi
    if grep -q "^$name " <<<"$have"; then
      retry gh release upload "$tag" "$f" --clobber
    else
      retry gh release upload "$tag" "$f"
    fi
  done
  # The manifest goes last, so its presence marks a complete release.
  retry gh release upload "$tag" "$dir/manifest-${S}.json"
  rm -rf "$dir"
done
