#!/bin/bash
# Overnight maintenance for a home media server.
# 1. Docker housekeeping (prune dangling images + build cache)
# 2. SHA-256 manifest compared with the previous completed scan
# 3. ffmpeg full-decode integrity scan of all video files
# 4. *arr (Sonarr/Radarr) download queue health check
# Reports land in ~/overnight-reports/<date>/.
#
# Run me under `nice -n 19 ionice -c3` (see crontab) -- every child inherits
# it, which is what keeps the media server responsive while this grinds.
#
# The integrity scan is time-boxed (SCAN_BUDGET_SEC) and banks its results in
# a persistent list ($SCANNED) that outlives the dated report dirs. A full
# pass over a large library takes several nights; each night resumes where the
# last one stopped, and once the library is fully scanned a run costs seconds.
set -u

# Overridable so the script can be exercised against a scratch tree.
MEDIA=${MEDIA:-/mnt/media}
REPORTS=${REPORTS:-$HOME/overnight-reports}
OUT="$REPORTS/$(date +%F)"
FF="$HOME/.local/bin/ffmpeg"
mkdir -p "$OUT"

# Paths that have passed a full decode, one per line, accumulated across runs.
# A clean decode is a property of the file as written, so a path in here is
# never rescanned; bitrot after the fact is what the checksum manifest catches.
# Only passes are banked -- failures are retried each run so a replaced file
# gets re-verified without manual bookkeeping.
SCANNED="$REPORTS/.scanned-ok"

SCAN_JOBS=${SCAN_JOBS:-2}              # parallel decodes; 4-core box, leave headroom
SCAN_BUDGET_SEC=${SCAN_BUDGET_SEC:-10800}   # stop starting new files after 3h
# Per-file timeout scales with the pixels the decoder has to touch, not with
# file size. Decode cost tracks resolution x framerate x runtime; file size
# only tracks bitrate, so a size-derived budget starves exactly the files that
# need it most -- a low-bitrate 4K HEVC feature is small on disk and expensive
# to decode. A real 4K HEVC 10-bit, 1h45m file measured ~5415s to decode but
# only got a fraction of that from a size-derived budget, so it re-failed and
# burned its budget every single night because failures are never banked.
#
# Measured single-thread throughput on this box: ~170-225 Mpix/s for HEVC
# 10-bit (the slow class), ~176-365 Mpix/s for 8-bit h264. Throughput is flat
# across resolutions within a codec, which is what makes pixels the right unit.
# 80 Mpix/s leaves ~2.8x headroom on the slowest observed case, covering the
# second worker and any concurrent transcode from the media server.
SCAN_FILE_TIMEOUT_SEC=${SCAN_FILE_TIMEOUT_SEC:-1800}           # floor: 30m
SCAN_FILE_TIMEOUT_MAX_SEC=${SCAN_FILE_TIMEOUT_MAX_SEC:-21600}  # ceiling: 6h
SCAN_TIMEOUT_PIXELS_PER_SEC=${SCAN_TIMEOUT_PIXELS_PER_SEC:-80000000}
# Retained purely as a lower bound, never as the cost model. If a container
# misreports duration -- an attached cover pic can drag it to ~0 -- the pixel
# budget collapses to the floor, and a large file would then fail exactly the
# way this fix exists to prevent. Bytes are a bad estimate of decode cost but a
# perfectly good sanity floor, so whichever budget is larger wins.
SCAN_TIMEOUT_BYTES_PER_SEC=${SCAN_TIMEOUT_BYTES_PER_SEC:-2097152}

export OUT FF SCANNED SCAN_FILE_TIMEOUT_SEC SCAN_FILE_TIMEOUT_MAX_SEC
export SCAN_TIMEOUT_PIXELS_PER_SEC SCAN_TIMEOUT_BYTES_PER_SEC

log() { echo "[$(date '+%F %T')] $*" >> "$OUT/run.log"; }

log "=== overnight maintenance start ==="

# --- 1. Docker housekeeping (dangling only; never touches in-use images) ---
log "docker prune..."
{ docker image prune -f; docker builder prune -f; } >> "$OUT/run.log" 2>&1
log "docker prune done"

# --- 2. Checksum manifest and verification ---
# Excludes backups (rotate daily) and downloads (incomplete/churning).
log "checksum manifest start"
# Publish only a complete scan. Never compare a partial manifest or silently
# reuse stale same-day entries after a file changed. Older manifests stay intact.
checksum_verify_rc=0
if (
    set -o pipefail
    find "$MEDIA" \( -path "$MEDIA/backups" -o -path "$MEDIA/downloads" \) -prune \
         -o -type f -print0 |
    while IFS= read -r -d '' f; do
        sha256sum "$f" || exit 1
    done
) > "$OUT/manifest.sha256.partial" 2>> "$OUT/errors.log"; then
    if mv "$OUT/manifest.sha256.partial" "$OUT/manifest.sha256"; then
        log "checksum manifest done: $(wc -l < "$OUT/manifest.sha256") files"
        python3 "$HOME/scripts/verify-manifests.py" "$OUT/manifest.sha256" --media-root "$MEDIA" \
            >> "$OUT/run.log" 2>> "$OUT/errors.log"
        checksum_verify_rc=$?
        if [ "$checksum_verify_rc" -ne 0 ]; then
            log "ATTENTION: checksum comparison needs review (status=$checksum_verify_rc); see checksum-verification.txt and errors.log"
        fi
    else
        checksum_verify_rc=2
    fi
else
    checksum_verify_rc=2
    log "ATTENTION: checksum scan incomplete; previous complete manifest preserved; see errors.log"
fi

# --- 3. Video integrity scan (full decode, time-boxed, parallel workers) ---
log "integrity scan start"
touch "$OUT/scan-ok.log" "$OUT/scan-corrupt.log" "$SCANNED"

# Stop starting new files once we're past the budget. Exported as an absolute
# epoch so every worker agrees on the deadline without re-reading a file.
SCAN_DEADLINE=$(( $(date +%s) + SCAN_BUDGET_SEC ))
export SCAN_DEADLINE

# NUL-separated list of video files not yet banked as passing. Filtering the
# passed paths out up front beats grepping $SCANNED once per worker -- one pass
# instead of O(n^2) over a list that only grows.
# -z keeps the NUL separation; patterns in $SCANNED stay newline-separated.
pending_videos() {
    find "$MEDIA" \( -path "$MEDIA/backups" -o -path "$MEDIA/downloads" \) -prune \
         -o -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \
            -o -iname '*.m4v' -o -iname '*.ts' -o -iname '*.webm' \
            -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.mpg' \
            -o -iname '*.mpeg' -o -iname '*.flv' \) -print0 |
    grep -zvxF -f "$SCANNED"
}

pending_videos |
xargs -0 -P"$SCAN_JOBS" -n1 bash -c '
    f="$1"
    [ "$(date +%s)" -ge "$SCAN_DEADLINE" ] && exit 0
    # -threads 1 keeps each worker to one core. Unpinned, ffmpeg spawns a
    # decode thread per core per file, and the runnable threads pile up into a
    # load average many times the core count for no extra throughput.
    #
    # -xerror is load-bearing: we trust the exit code rather than stderr (at
    # -v error ffmpeg still prints non-fatal notes -- the null muxer complains
    # about non-monotonic dts, mjpeg cover art fails to decode -- on files that
    # are perfectly fine), but *without* -xerror ffmpeg exits 0 on frame-level
    # corruption and only fails when a file will not demux at all. That made
    # the decode pure waste: it caught nothing ffprobe would not catch in
    # milliseconds. -xerror makes the exit code mean what we already assumed.
    # Budget from the decode work ahead. Anchor the stream match on "Stream #":
    # ffmpeg also emits diagnostics that contain "Video:" (e.g. "Could not find
    # codec parameters for stream 22 (Video: mjpeg ...)"), and matching one of
    # those reads the cover art instead of the feature -- which would hand a
    # 2h film a 30m floor. Attached pics are skipped for the same reason.
    probe=$(timeout 60 "$FF" -nostdin -hide_banner -i "$f" 2>&1)
    vid=$(printf "%s\n" "$probe" | grep -E "^ *Stream #.*Video:" | grep -v "attached pic" | head -1)
    res=$(printf "%s\n" "$vid" | grep -oE "[0-9]{3,5}x[0-9]{3,5}" | head -1)
    fps=$(printf "%s\n" "$vid" | grep -oE "[0-9]+(\.[0-9]+)? (fps|tbr)" | head -1 | cut -d" " -f1)
    hms=$(printf "%s\n" "$probe" | grep -oE "Duration: [0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 | cut -d" " -f2)
    # Lower bound: the flat floor, raised by the size-derived value so a file
    # that probes badly still gets time proportional to how much there is.
    lo=$(( $(stat -c %s "$f" 2>/dev/null || echo 0) / SCAN_TIMEOUT_BYTES_PER_SEC ))
    [ "$lo" -lt "$SCAN_FILE_TIMEOUT_SEC" ] && lo=$SCAN_FILE_TIMEOUT_SEC
    if [ -n "$res" ] && [ -n "$fps" ] && [ -n "$hms" ]; then
        secs=$(( 10#${hms:0:2} * 3600 + 10#${hms:3:2} * 60 + 10#${hms:6:2} ))
        to=$(awk -v w="${res%x*}" -v h="${res#*x}" -v f="$fps" -v d="$secs" \
                 -v r="$SCAN_TIMEOUT_PIXELS_PER_SEC" -v lo="$lo" \
                 -v hi="$SCAN_FILE_TIMEOUT_MAX_SEC" \
                 "BEGIN{t=(w*h*f*d)/r; if(t<lo)t=lo; if(t>hi)t=hi; printf \"%d\", t}")
    else
        # Unprobeable: either genuinely broken (those fail in milliseconds, so
        # the timeout never comes into play) or metadata we cannot read.
        secs=""; to=$lo
    fi
    err=$(timeout "$to" \
          "$FF" -nostdin -threads 1 -xerror -v error -i "$f" -f null - 2>&1); rc=$?
    err=${err:0:2000}
    if [ $rc -eq 124 ]; then
        # Record what the budget was derived from -- a timeout is either a real
        # hang or a bad rate constant, and these fields tell the two apart.
        { printf "BAD: %s\ntimed out after %ss (%s @ %s fps, %ss runtime)\n---\n" \
            "$f" "$to" "${res:-unprobed}" "${fps:-?}" "${secs:-?}"; } >> "$OUT/scan-corrupt.log"
    elif [ $rc -ne 0 ]; then
        { printf "BAD: %s\n%s\n---\n" "$f" "$err"; } >> "$OUT/scan-corrupt.log"
    else
        echo "OK: $f" >> "$OUT/scan-ok.log"
        # Bank the pass so future runs skip it. Short O_APPEND writes from a
        # couple of workers do not interleave.
        echo "$f" >> "$SCANNED"
    fi
' _
remaining=$(pending_videos | grep -zc . || true)
log "integrity scan done: $(grep -c '^OK:' "$OUT/scan-ok.log") ok this run, $(grep -c '^BAD:' "$OUT/scan-corrupt.log") bad this run, $(wc -l < "$SCANNED") banked, $remaining still to scan"

# --- 4. *arr queue health check ---
# Sonarr/Radarr park a grab in the queue with a warning status instead of
# importing it when something looks wrong (e.g. Radarr's dangerous-extension
# block). That's the right call, but nothing surfaced it on its own -- a
# flagged download once sat unnoticed for two days despite Radarr correctly
# blocking it. This just puts flagged items in the report so they don't go
# unnoticed again.
log "arr queue check start"
: > "$OUT/queue-warnings.log"
check_arr_queue() {
    local name="$1" port="$2" key="$3"
    [ -z "$key" ] && return
    curl -s --max-time 10 "http://localhost:$port/api/v3/queue" -H "X-Api-Key: $key" |
    jq -r --arg app "$name" '
        .records[]?
        | select(.trackedDownloadStatus == "warning" or .trackedDownloadStatus == "error")
        | "\($app): \(.title)\n  status: \(.trackedDownloadStatus)/\(.trackedDownloadState)\n  messages: \([.statusMessages[]?.messages[]?] | join("; "))\n"
    ' 2>> "$OUT/errors.log"
}
{
    check_arr_queue Sonarr 8989 "$(grep -oP '(?<=<ApiKey>)[^<]+' /opt/sonarr/config.xml 2>/dev/null)"
    check_arr_queue Radarr 7878 "$(grep -oP '(?<=<ApiKey>)[^<]+' /opt/radarr/config.xml 2>/dev/null)"
} >> "$OUT/queue-warnings.log"
warn_count=$(grep -cE '^(Sonarr|Radarr): ' "$OUT/queue-warnings.log" || true)
log "arr queue check done: $warn_count flagged item(s)"

log "=== overnight maintenance complete ==="
exit "$checksum_verify_rc"
