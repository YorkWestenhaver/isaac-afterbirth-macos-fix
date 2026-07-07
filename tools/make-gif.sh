#!/bin/bash
#
# make-gif.sh -- turn a screen recording (.mov/.mp4) into a small, good-looking
# GIF suitable for a README, using ffmpeg's two-pass palette method.
#
# Usage:
#   ./make-gif.sh input.mov [output.gif] [width] [fps] [start] [duration]
#
# Examples:
#   ./make-gif.sh demo.mov                       # 640px wide, 15fps, whole clip
#   ./make-gif.sh demo.mov demo.gif 480 12       # 480px wide, 12fps (smaller)
#   ./make-gif.sh demo.mov demo.gif 640 15 3 8   # start at 3s, 8s long
#
# Tips for a small file: shorter clip, lower fps (12-15), smaller width
# (480-640). GitHub renders GIFs up to a few MB fine; aim for < 5 MB.
#
set -euo pipefail

IN="${1:?usage: make-gif.sh input.mov [output.gif] [width] [fps] [start] [duration]}"
OUT="${2:-${IN%.*}.gif}"
WIDTH="${3:-640}"
FPS="${4:-15}"
START="${5:-}"
DURATION="${6:-}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg not found. Install it with: brew install ffmpeg" >&2
    exit 1
fi

TRIM=()
[ -n "$START" ]    && TRIM+=(-ss "$START")
[ -n "$DURATION" ] && TRIM+=(-t "$DURATION")

FILTER="fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"

echo "==> Encoding $OUT (${WIDTH}px, ${FPS}fps)..."
ffmpeg -y "${TRIM[@]}" -i "$IN" -vf "$FILTER" -loop 0 "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
echo "==> Done: $OUT ($SIZE)"
echo "    If it's too big, re-run with a smaller width/fps or a shorter clip, e.g.:"
echo "    ./make-gif.sh \"$IN\" \"$OUT\" 480 12"
