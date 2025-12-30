#!/bin/sh
set -eu

RENDERER_URL="${RENDERER_URL:-http://renderer:3000/stream.ts}"
OUTPUT_M3U8="${OUTPUT_M3U8:-/output/weather.m3u8}"

echo "[hls] Starting HLS packager..."
echo "[hls] Input:  ${RENDERER_URL}"
echo "[hls] Output: ${OUTPUT_M3U8}"

while true; do
  ffmpeg \
    -hide_banner -loglevel info \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -fflags +genpts \
    -i "${RENDERER_URL}" \
    \
    -map 0:v:0 \
    -map 0:a? \
    -c:v copy \
    -c:a copy \
    \
    -f hls \
    -hls_time 4 \
    -hls_list_size 10 \
    -hls_flags delete_segments+append_list+omit_endlist+independent_segments+temp_file \
    -hls_segment_filename /hls/weather_%05d.ts \
    "${OUTPUT_M3U8}" || true

  echo "[hls] ffmpeg exited. Restarting in 2s..."
  sleep 2
done
