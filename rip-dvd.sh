#!/usr/bin/env bash
# rip-dvd.sh — rip a DVD, transcode to H.265, drop into Jellyfin library.
#
# Usage:
#   rip-dvd.sh "Movie Name" 2024            # auto-pick longest title
#   rip-dvd.sh "Movie Name" 2024 3          # pick title #3
#   rip-dvd.sh --tv "Show Name" 1 2         # TV mode: Show, season, episode (uses longest title)
#
# Requires: makemkvcon, HandBrakeCLI, libdvd-pkg configured.
# Set JELLYFIN_API_KEY in the environment to trigger a library scan when done
# (optional — the rip and transcode work fine without it).

set -euo pipefail

DEV="${DVD_DEV:-/dev/sr0}"
MEDIA_ROOT="${MEDIA_ROOT:-/mnt/media}"
WORK_DIR="${WORK_DIR:-$MEDIA_ROOT/_rips}"
PRESET="${HB_PRESET:-H.265 MKV 1080p30}"
MIN_TITLE_SECS="${MIN_TITLE_SECS:-600}"   # ignore titles shorter than 10 min when auto-picking

TV_MODE=0
if [[ "${1:-}" == "--tv" ]]; then
  TV_MODE=1; shift
  NAME="${1:?show name required}"; SEASON="${2:?season required}"; EPISODE="${3:?episode required}"
  TITLE_ARG="${4:-auto}"
else
  NAME="${1:?movie name required}"; YEAR="${2:?year required}"
  TITLE_ARG="${3:-auto}"
fi

NAME="${NAME//\//-}"   # slashes in the name would create stray directories

command -v makemkvcon  >/dev/null || { echo "makemkvcon not found"; exit 1; }
command -v HandBrakeCLI >/dev/null || { echo "HandBrakeCLI not found"; exit 1; }
[[ -b "$DEV" ]] || { echo "No disc at $DEV"; exit 1; }
mkdir -p "$WORK_DIR"

MIN_FREE_GB="${MIN_FREE_GB:-12}"   # raw rip + transcode can need ~10GB
FREE_GB=$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc '0-9')
(( FREE_GB >= MIN_FREE_GB )) || { echo "Only ${FREE_GB}GB free in $WORK_DIR (need ${MIN_FREE_GB}GB)"; exit 1; }

# Work out the destination up front so we fail before a 30-minute rip,
# not after it.
if [[ $TV_MODE -eq 1 ]]; then
  SE=$(printf "S%02dE%02d" "$SEASON" "$EPISODE")
  OUT_DIR="$MEDIA_ROOT/TV/$NAME/Season $(printf '%02d' "$SEASON")"
  OUT_FILE="$OUT_DIR/$NAME - $SE.mkv"
else
  OUT_DIR="$MEDIA_ROOT/Movies/$NAME ($YEAR)"
  OUT_FILE="$OUT_DIR/$NAME ($YEAR).mkv"
fi
[[ -e "$OUT_FILE" ]] && { echo "Refusing to overwrite existing $OUT_FILE"; exit 1; }

pick_title() {
  if [[ "$TITLE_ARG" != "auto" ]]; then
    echo "$TITLE_ARG"; return
  fi
  # Parse makemkvcon -r info: TINFO:<id>,9,0,"HH:MM:SS"  -> longest above MIN_TITLE_SECS
  makemkvcon -r --cache=1 info "dev:$DEV" 2>/dev/null \
    | awk -F, -v min="$MIN_TITLE_SECS" '
        /^TINFO:/ && $2==9 {
          gsub(/"/,"",$4); split($4,t,":"); secs=t[1]*3600+t[2]*60+t[3];
          id=$1; sub(/TINFO:/,"",id);
          if (secs>=min && secs>best) { best=secs; pick=id }
        }
        END { if (pick=="") exit 1; print pick }'
}

TITLE_ID=$(pick_title) || { echo "No suitable title found (>= ${MIN_TITLE_SECS}s). Run: makemkvcon info dev:$DEV"; exit 1; }
echo ">> Ripping title $TITLE_ID from $DEV"

RIP_DIR=$(mktemp -d "$WORK_DIR/rip.XXXXXX")
# Keep the raw rip if the transcode fails so it can be retried without
# re-ripping the disc; otherwise clean up, including on early failures.
KEEP_RAW=0
trap 'if (( KEEP_RAW )); then echo ">> Raw rip kept for retry: $RIP_DIR"; else rm -rf "$RIP_DIR"; fi' EXIT

makemkvcon mkv "dev:$DEV" "$TITLE_ID" "$RIP_DIR"

RAW_MKV=$(find "$RIP_DIR" -name '*.mkv' -printf '%s %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)
[[ -f "$RAW_MKV" ]] || { echo "Rip produced no MKV"; exit 1; }
echo ">> Raw rip: $RAW_MKV"

mkdir -p "$OUT_DIR"

echo ">> Transcoding -> $OUT_FILE"
KEEP_RAW=1
HandBrakeCLI -i "$RAW_MKV" -o "$OUT_FILE" --preset "$PRESET" --all-subtitles --all-audio
KEEP_RAW=0
eject "$DEV" 2>/dev/null || true

echo ">> Done. File: $OUT_FILE"

JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"
if [[ -n "$JELLYFIN_API_KEY" ]] && curl -fsS -m 10 -X POST -H "X-Emby-Token: $JELLYFIN_API_KEY" "$JELLYFIN_URL/Library/Refresh" >/dev/null; then
  echo ">> Jellyfin library scan triggered."
else
  echo ">> Could not trigger Jellyfin scan (or JELLYFIN_API_KEY not set); run it from Dashboard > Libraries."
fi
