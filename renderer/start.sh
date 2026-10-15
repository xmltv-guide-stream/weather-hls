#!/usr/bin/env bash
# Renderer: Xvfb display + Chromium (supervised by app.js) + FFmpeg capture -> HLS.
#
# Each piece runs in its own restart loop, so a browser crash, an encoder hiccup or a
# bad music file never takes the others down. Only losing the X server itself is fatal.
set -uo pipefail

W="${VIEWPORT_W:-1280}"
H="${VIEWPORT_H:-720}"
FPS="${CAPTURE_FPS:-30}"
BITRATE="${VIDEO_BITRATE:-3500k}"
CROP_Y="${CROP_Y:-0}"                      # pixels to crop off the top (output is scaled back to WxH)
DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

HLS_DIR="${HLS_DIR:-/hls}"
HLS_NAME="${HLS_NAME:-weather}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-8}"
export HLS_PLAYLIST="${HLS_DIR}/${HLS_NAME}.m3u8"

# music = shuffled files from MUSIC_DIR | page = the web page's own audio | none = silence
AUDIO_SOURCE="${AUDIO_SOURCE:-music}"
MUSIC_DIR="${MUSIC_DIR:-/music}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_GAIN_DB="${AUDIO_GAIN_DB:-0}"
export AUDIO_SOURCE

# auto | h264_nvenc | h264_qsv | h264_vaapi | libx264
VIDEO_ENCODER="${VIDEO_ENCODER:-auto}"
X264_PRESET="${X264_PRESET:-veryfast}"
NVENC_PRESET="${NVENC_PRESET:-p4}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

PERSIST_PROFILE_DIR="${PERSIST_PROFILE_DIR:-/profile}"
export USER_DATA_DIR="${RUNTIME_PROFILE_DIR:-/tmp/chrome-profile}"

log() { echo "[renderer $(date +%H:%M:%S)] $*"; }

# On stop, take down every background loop and process started from this script.
trap 'trap - TERM INT; log "shutting down"; kill 0 2>/dev/null; exit 0' TERM INT

# Run a command forever, restarting it (with a short backoff) whenever it exits.
supervise() {
  local name="$1"; shift
  while true; do
    "$@"
    log "${name} exited with code $?, restarting in 2s"
    sleep 2
  done
}

# ---------------------------------------------------------------- display
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
log "starting Xvfb ${DISPLAY} at ${W}x${H}"
Xvfb "${DISPLAY}" -screen 0 "${W}x${H}x24" -nolisten tcp -noreset -dpi 96 &
XVFB_PID=$!
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
  sleep 0.1
done
if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
  log "ERROR: Xvfb failed to start"
  exit 1
fi

# ---------------------------------------------------------------- page audio (optional)
if [ "${AUDIO_SOURCE}" = "page" ]; then
  export PULSE_SERVER="unix:/tmp/pulse.sock"
  log "starting PulseAudio null sink for page audio"
  pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit -n \
    --load="module-native-protocol-unix socket=/tmp/pulse.sock auth-anonymous=1" \
    --load="module-null-sink sink_name=page rate=48000 channels=2" \
    --load="module-always-sink" >/dev/null 2>&1 || log "WARNING: PulseAudio failed to start"
fi

# ---------------------------------------------------------------- browser
# Seed the runtime profile from the persisted one (if any) once per container start.
rm -rf "${USER_DATA_DIR}"
mkdir -p "${USER_DATA_DIR}"
if [ -d "${PERSIST_PROFILE_DIR}" ] && [ -n "$(ls -A "${PERSIST_PROFILE_DIR}" 2>/dev/null)" ]; then
  log "seeding Chromium profile from ${PERSIST_PROFILE_DIR}"
  cp -a "${PERSIST_PROFILE_DIR}/." "${USER_DATA_DIR}/" 2>/dev/null || true
fi

supervise browser node /app/app.js &

# ---------------------------------------------------------------- audio input
AUDIO_FIFO=/tmp/audio.pcm
AUDIO_INPUT_ARGS=()
AUDIO_FILTER="aresample=48000"

music_feeder() {
  # One pass over the library in a fresh random order, decoded to raw PCM at real-time pace.
  local list=/tmp/music.ffconcat
  mapfile -t tracks < <(find "${MUSIC_DIR}" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.ogg' -o -iname '*.flac' -o -iname '*.wav' \) | shuf)
  if [ "${#tracks[@]}" -eq 0 ]; then
    sleep 10
    return 1
  fi
  {
    echo "ffconcat version 1.0"
    for f in "${tracks[@]}"; do
      echo "file '${f//\'/\'\\\'\'}'"
    done
  } > "${list}"
  log "music: playing ${#tracks[@]} tracks in shuffled order"
  ffmpeg -nostdin -hide_banner -loglevel error -re -f concat -safe 0 -i "${list}" \
    -vn -ac 2 -ar 48000 -f s16le pipe:1 > "${AUDIO_FIFO}"
}

case "${AUDIO_SOURCE}" in
  music)
    if [ -n "$(find "${MUSIC_DIR}" -type f 2>/dev/null | head -1)" ]; then
      rm -f "${AUDIO_FIFO}"
      mkfifo "${AUDIO_FIFO}"
      # Hold the FIFO open read-write so the encoder never sees EOF between music passes.
      exec 3<>"${AUDIO_FIFO}"
      supervise music music_feeder &
      AUDIO_INPUT_ARGS=(-thread_queue_size 512 -use_wallclock_as_timestamps 1
        -f s16le -ar 48000 -ac 2 -i "${AUDIO_FIFO}")
      # Timestamps are arrival times, so resample against them: this absorbs gaps between
      # passes and keeps audio locked to the video clock over days of uptime.
      AUDIO_FILTER="aresample=48000:async=1000:min_hard_comp=0.1:first_pts=0"
    else
      log "no music files in ${MUSIC_DIR}, using silence"
      AUDIO_SOURCE=none
    fi
    ;;
  page)
    AUDIO_INPUT_ARGS=(-thread_queue_size 512 -f pulse -i page.monitor)
    AUDIO_FILTER="aresample=48000:async=1000:min_hard_comp=0.1:first_pts=0"
    ;;
esac
if [ "${AUDIO_SOURCE}" = "none" ]; then
  AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000")
fi
if [ "${AUDIO_GAIN_DB}" != "0" ]; then
  AUDIO_FILTER="${AUDIO_FILTER},volume=${AUDIO_GAIN_DB}dB"
fi

# ---------------------------------------------------------------- video encoder
# "auto" picks the first hardware encoder that can actually encode a test frame here
# (being compiled into ffmpeg is not enough), falling back to libx264.
encoder_works() {
  local extra=()
  [ "$1" = "h264_vaapi" ] && extra=(-vaapi_device "${VAAPI_DEVICE}" -vf format=nv12,hwupload)
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=black:size=${W}x${H}:rate=${FPS}" \
    -frames:v 5 "${extra[@]}" -c:v "$1" -f null - >/dev/null 2>&1
}
ENC="${VIDEO_ENCODER}"
if [ "${ENC}" = "auto" ]; then
  ENC=libx264
  for candidate in h264_nvenc h264_qsv h264_vaapi; do
    if encoder_works "${candidate}"; then ENC="${candidate}"; break; fi
  done
fi
log "video encoder: ${ENC}"

GOP=$((FPS * 2))
VF=""
[ "${CROP_Y}" -gt 0 ] && VF="crop=${W}:$((H - CROP_Y)):0:${CROP_Y},scale=${W}:${H},"
HW_INIT_ARGS=()
case "${ENC}" in
  h264_nvenc)
    # NVENC takes the captured BGR frames directly and converts on the GPU.
    VF="${VF%,}"
    VENC_ARGS=(-c:v h264_nvenc -preset "${NVENC_PRESET}" -tune hq -profile:v high
      -rc vbr -cq 23 -b:v "${BITRATE}" -maxrate "${BITRATE}" -bufsize "${BITRATE}"
      -bf 2 -forced-idr 1 -no-scenecut 1)
    ;;
  h264_qsv)
    VF="${VF}format=nv12"
    VENC_ARGS=(-c:v h264_qsv -global_quality 23 -look_ahead 0 -b:v "${BITRATE}" -maxrate "${BITRATE}")
    ;;
  h264_vaapi)
    HW_INIT_ARGS=(-vaapi_device "${VAAPI_DEVICE}")
    VF="${VF}format=nv12,hwupload"
    VENC_ARGS=(-c:v h264_vaapi -b:v "${BITRATE}" -maxrate "${BITRATE}")
    ;;
  *)
    VF="${VF}format=yuv420p"
    # Capped CRF: mostly-static weather graphics need far fewer bits than the cap most of
    # the time, which saves CPU, disk and bandwidth versus constant bitrate.
    VENC_ARGS=(-c:v libx264 -preset "${X264_PRESET}" -profile:v high -crf 23
      -maxrate "${BITRATE}" -bufsize "${BITRATE}" -x264-params "scenecut=0:rc-lookahead=10")
    ;;
esac
VF_ARGS=()
[ -n "${VF}" ] && VF_ARGS=(-vf "${VF}")

mkdir -p "${HLS_DIR}"
rm -f "${HLS_DIR}/${HLS_NAME}"*

run_encoder() {
  ffmpeg -nostdin -hide_banner -nostats -loglevel warning \
    "${HW_INIT_ARGS[@]}" \
    -thread_queue_size 16 \
    -f x11grab -draw_mouse 0 -framerate "${FPS}" -video_size "${W}x${H}" -i "${DISPLAY}.0+0,0" \
    "${AUDIO_INPUT_ARGS[@]}" \
    -map 0:v:0 -map 1:a:0 \
    "${VF_ARGS[@]}" "${VENC_ARGS[@]}" \
    -g "${GOP}" -keyint_min "${GOP}" -force_key_frames "expr:gte(t,n_forced*2)" \
    -af "${AUDIO_FILTER}" -c:a aac -b:a "${AUDIO_BITRATE}" -ac 2 \
    -f hls -hls_time "${HLS_TIME}" -hls_list_size "${HLS_LIST_SIZE}" \
    -hls_delete_threshold 2 \
    -hls_flags delete_segments+append_list+omit_endlist+independent_segments+temp_file \
    -hls_segment_filename "${HLS_DIR}/${HLS_NAME}_%05d.ts" \
    "${HLS_PLAYLIST}" &
  echo $! > /tmp/encoder.pid
  wait $!
}

log "capturing ${W}x${H}@${FPS} (max ${BITRATE}, audio=${AUDIO_SOURCE}) -> ${HLS_PLAYLIST}"
supervise encoder run_encoder &

# ---------------------------------------------------------------- watchdog
# Restart the encoder if the playlist stops updating (e.g. a wedged capture).
STALE_AFTER=$((HLS_TIME * 6))
sleep 30
while true; do
  if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
    log "ERROR: Xvfb died, exiting so the container restarts"
    kill 0
    exit 1
  fi
  if [ -f "${HLS_PLAYLIST}" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "${HLS_PLAYLIST}") ))
    if [ "${age}" -gt "${STALE_AFTER}" ]; then
      log "playlist not updated for ${age}s, restarting encoder"
      kill "$(cat /tmp/encoder.pid 2>/dev/null)" 2>/dev/null
      sleep "${STALE_AFTER}"
    fi
  fi
  sleep 5
done
