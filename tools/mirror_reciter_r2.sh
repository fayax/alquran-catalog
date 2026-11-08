#!/usr/bin/env bash
# Mirrors one reciter's ayah-by-ayah files into a Cloudflare R2 bucket:
#   audio/<reciter>/SSSAAA.mp3        (Content-Type audio/mpeg)
#   audio/<reciter>/manifest-SSS.json (size and sha256 of every file)
# The manifest is uploaded last, so its presence marks a complete surah,
# and surahs that already have one are skipped. Safe to re-run.
#
# Usage: tools/mirror_reciter_r2.sh <reciter> <source-url-template> <first> <last>
#   The template uses {surah3} and {ayah3}, for example
#   https://audio-cdn.tarteel.ai/quran/alafasy/{surah3}{ayah3}.mp3
# Needs R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET,
# and aws, curl, sha256sum.
set -euo pipefail

reciter="$1"; template="$2"; first="$3"; last="$4"

# Ayahs per surah (Hafs, 6,236 in all).
counts=(0 7 286 200 176 120 165 206 75 129 109 123 111 43 52 99 128 111 110 98 135
  112 78 118 64 77 227 93 88 69 60 34 30 73 54 45 83 182 88 75 85 54 53 89 59 37
  35 38 29 18 45 60 49 62 55 78 96 29 22 24 13 14 11 11 18 12 12 30 52 52 44 28
  28 20 56 40 31 50 40 46 42 29 19 36 25 22 17 19 26 30 20 15 21 11 8 8 19 5 8 8
  11 11 8 3 9 5 4 7 3 6 3 5 4 5 6)

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# R2 does not accept every checksum newer AWS CLIs send by default.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
s3() { aws --endpoint-url "https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" "$@"; }
prefix="audio/$reciter"
work="$(mktemp -d)"

for ((s = first; s <= last; s++)); do
  S=$(printf '%03d' "$s")
  n=${counts[$s]}
  if s3 s3api head-object --bucket "$R2_BUCKET" --key "$prefix/manifest-$S.json" >/dev/null 2>&1; then
    echo "$reciter $S: already mirrored"
    continue
  fi
  dir="$work/$S"; mkdir -p "$dir"
  echo "$reciter $S: downloading $n ayahs"
  for ((a = 1; a <= n; a++)); do
    A=$(printf '%03d' "$a")
    url="${template//\{surah3\}/$S}"; url="${url//\{ayah3\}/$A}"
    curl -fsSL --retry 5 --retry-delay 3 -o "$dir/${S}${A}.mp3" "$url"
    # An MP3 starts with an ID3 tag or a frame sync.
    head -c 3 "$dir/${S}${A}.mp3" | grep -q 'ID3' ||
      [ "$(head -c 2 "$dir/${S}${A}.mp3" | od -An -tx1 | tr -d ' ' | cut -c1-3)" = "fff" ] || {
        echo "::error::$url is not an MP3"; exit 1; }
  done
  [ "$(ls "$dir"/*.mp3 | wc -l)" -eq "$n" ] || { echo "::error::$S count"; exit 1; }
  {
    printf '{"reciter":"%s","surah":%d,"files":{' "$reciter" "$s"
    sep=""
    for f in "$dir"/*.mp3; do
      printf '%s"%s":{"size":%d,"sha256":"%s"}' "$sep" "$(basename "$f")" \
        "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
      sep=","
    done
    printf '}}\n'
  } > "$dir/manifest-$S.json"

  # Ayah files never change, so clients may cache them for a year.
  s3 s3 cp "$dir" "s3://$R2_BUCKET/$prefix/" --recursive --exclude '*' --include '*.mp3' \
    --content-type audio/mpeg --cache-control 'public, max-age=31536000, immutable' \
    --only-show-errors
  s3 s3 cp "$dir/manifest-$S.json" "s3://$R2_BUCKET/$prefix/manifest-$S.json" \
    --content-type application/json --cache-control 'public, max-age=3600' --only-show-errors
  echo "$reciter $S: uploaded"
  rm -rf "$dir"
done
