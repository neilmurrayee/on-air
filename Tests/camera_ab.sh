#!/bin/bash
# Does On Air cost the camera, or the compositor, anything? Captures from a camera
# with On Air quit, then with it running and the banner up, and compares delivered
# frames, dropped frames and WindowServer CPU.
#
#   Tests/camera_ab.sh            camera 0, 30 s per run
#   Tests/camera_ab.sh 1 60       camera 1, 60 s per run
#
# Run it when no call is using the camera: ffmpeg opens the camera itself, and a
# different capture format could disturb whoever else has it open. Needs ffmpeg,
# and the terminal needs camera permission the first time. Camera indices:
#   ffmpeg -f avfoundation -list_devices true -i ""
set -euo pipefail

CAMERA="${1:-0}"
SECONDS_PER_RUN="${2:-30}"
APP="/Applications/On Air.app"
BINARY="$APP/Contents/MacOS/OnAir"

command -v ffmpeg >/dev/null || { echo "needs ffmpeg (brew install ffmpeg)"; exit 1; }

# One run: capture in the background, sample WindowServer meanwhile.
run() {
    local label="$1" log
    log="$(mktemp)"
    ffmpeg -hide_banner -nostats -loglevel info -stats_period 1 -progress pipe:2 \
        -f avfoundation -framerate 30 -i "${CAMERA}:none" \
        -t "$SECONDS_PER_RUN" -f null - 2>"$log" &
    local ff=$!
    sleep 3   # let the camera start before sampling
    local ws
    ws=$(top -l $((SECONDS_PER_RUN / 2 - 2)) -s 2 -stats cpu -pid "$(pgrep -x WindowServer)" \
        | grep -E '^[0-9.]+ *$' | tail -n +2 | awk '{s+=$1; n++} END {printf "%.1f", n ? s/n : 0}')
    wait $ff || { echo "ffmpeg failed:"; tail -5 "$log"; exit 1; }
    local frames drops
    frames=$(grep -Eo '^frame=[0-9]+' "$log" | tail -1 | cut -d= -f2)
    drops=$(grep -Eo '^drop_frames=[0-9]+' "$log" | tail -1 | cut -d= -f2)
    printf "%-26s frames %5s (%.1f fps)   dropped %3s   WindowServer %5s%% CPU\n" \
        "$label" "${frames:-?}" "$(echo "${frames:-0} / $SECONDS_PER_RUN" | bc -l)" "${drops:-?}" "$ws"
    rm -f "$log"
}

echo "Camera $CAMERA, ${SECONDS_PER_RUN}s per run"

pkill -f "$BINARY" 2>/dev/null || true
sleep 2
run "On Air quit:"

# The capture itself makes the camera live, so On Air raises its banner on its own.
open "$APP"
sleep 3
run "On Air running, banner up:"

echo "On Air left running."
