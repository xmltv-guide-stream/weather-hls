#!/usr/bin/env bash
set -euo pipefail

W="${VIEWPORT_W:-1280}"
H="${VIEWPORT_H:-720}"
FPS="${CAPTURE_FPS:-30}"

# Support either VIDEO_BITRATE (compose) or BITRATE (older env)
BITRATE="${VIDEO_BITRATE:-${BITRATE:-3500k}}"

CROP_Y="${CROP_Y:-30}"                 # crop off top bar; set 0 to disable
DISPLAY_NUM="${DISPLAY_NUM:-99}"
DISPLAY=":${DISPLAY_NUM}"
HEALTH_PORT="${HEALTH_PORT:-3001}"
STREAM_PORT="${STREAM_PORT:-3000}"

# --- Music settings ---
MUSIC_DIR="${MUSIC_DIR:-/music}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_GAIN_DB="${AUDIO_GAIN_DB:-0}"

# --- Video encoder settings (NEW) ---
# Choose: libx264 | h264_nvenc | h264_qsv | h264_vaapi | auto
VIDEO_ENCODER="${VIDEO_ENCODER:-libx264}"

# x264 settings
X264_PRESET="${X264_PRESET:-veryfast}"

# NVENC settings
NVENC_PRESET="${NVENC_PRESET:-p3}"
NVENC_RC="${NVENC_RC:-cbr}"                 # cbr|vbr|cbr_hq|vbr_hq etc (depends on ffmpeg build)
NVENC_PROFILE="${NVENC_PROFILE:-high}"

# QSV settings
QSV_TARGET_USAGE="${QSV_TARGET_USAGE:-4}"   # 1=best quality .. 7=best speed (typical)

# VAAPI settings
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

# This is the *persisted* profile path (usually a volume mount)
PERSIST_PROFILE_DIR="${USER_DATA_DIR:-/profile}"

# This is the *runtime* profile path (inside container FS, avoids lock issues)
RUNTIME_PROFILE_DIR="${RUNTIME_PROFILE_DIR:-/tmp/chrome-profile}"

CLEANED=0
cleanup() {
  if [ "$CLEANED" -eq 1 ]; then return; fi
  CLEANED=1
  echo "[renderer] Shutting down..."
  kill -TERM "${FFMPEG_PID:-0}"  >/dev/null 2>&1 || true
  kill -TERM "${APP_PID:-0}"     >/dev/null 2>&1 || true
  kill -TERM "${OPENBOX_PID:-0}" >/dev/null 2>&1 || true
  kill -TERM "${XVFB_PID:-0}"    >/dev/null 2>&1 || true
  wait >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[renderer] Starting Xvfb on ${DISPLAY} (${W}x${H})..."
Xvfb "${DISPLAY}" -screen 0 "${W}x${H}x24" -ac +extension RANDR +render -noreset >/tmp/xvfb.log 2>&1 &
XVFB_PID="$!"

echo "[renderer] Waiting for X server..."
for _ in $(seq 1 200); do
  if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then break; fi
  sleep 0.05
done

echo "[renderer] Starting openbox window manager..."
DISPLAY="${DISPLAY}" openbox-session >/tmp/openbox.log 2>&1 &
OPENBOX_PID="$!"

# Kill any leftover chromium/chrome processes (in case of weird previous runs)
pkill -9 chromium >/dev/null 2>&1 || true
pkill -9 chrome   >/dev/null 2>&1 || true

# Build a fresh runtime profile every start to avoid SingletonLock issues
echo "[renderer] Preparing runtime Chromium profile..."
rm -rf "${RUNTIME_PROFILE_DIR}" || true
mkdir -p "${RUNTIME_PROFILE_DIR}"

# If persisted profile exists and has content, copy it in
if [ -d "${PERSIST_PROFILE_DIR}" ] && [ "$(ls -A "${PERSIST_PROFILE_DIR}" 2>/dev/null || true)" ]; then
  echo "[renderer] Copying persisted profile -> runtime profile..."
  cp -a "${PERSIST_PROFILE_DIR}/." "${RUNTIME_PROFILE_DIR}/" 2>/dev/null || true
fi

# Remove any lock artifacts in the runtime profile (all types: files/sockets)
echo "[renderer] Removing any Chromium lock artifacts in runtime profile..."
find "${RUNTIME_PROFILE_DIR}" -maxdepth 12 \( \
  -name 'SingletonLock' -o -name 'SingletonSocket' -o -name 'SingletonCookie' -o -name 'LOCK' -o -name '.parentlock' \
\) -print -exec rm -f {} \; 2>/dev/null || true

echo "[renderer] Starting Chromium via Puppeteer..."
# IMPORTANT: override USER_DATA_DIR for node so puppeteer launches using runtime profile
DISPLAY="${DISPLAY}" USER_DATA_DIR="${RUNTIME_PROFILE_DIR}" node /app/app.js >/tmp/puppeteer.log 2>&1 &
APP_PID="$!"

echo "[renderer] Waiting for /health ok:true..."
for _ in $(seq 1 180); do
  if wget -qO- "http://127.0.0.1:${HEALTH_PORT}/health" | grep -q '"ok":true'; then
    break
  fi
  if ! kill -0 "${APP_PID}" >/dev/null 2>&1; then
    echo "[renderer] ERROR: puppeteer process exited"
    echo "---- puppeteer.log ----"
    tail -n 250 /tmp/puppeteer.log || true
    echo "---- xvfb.log ----"
    tail -n 80 /tmp/xvfb.log || true
    echo "---- openbox.log ----"
    tail -n 80 /tmp/openbox.log || true
    exit 1
  fi
  sleep 1
done

if ! wget -qO- "http://127.0.0.1:${HEALTH_PORT}/health" | grep -q '"ok":true'; then
  echo "[renderer] ERROR: /health never became ok:true"
  echo "---- puppeteer.log ----"
  tail -n 250 /tmp/puppeteer.log || true
  exit 1
fi

# Build crop filter
VF="format=yuv420p"
if [ "${CROP_Y}" -gt 0 ]; then
  NEW_H=$((H - CROP_Y))
  VF="crop=${W}:${NEW_H}:0:${CROP_Y},format=yuv420p"
fi

# --- Build a shuffled, looping music playlist (if mp3s exist) ---
PLAYLIST="/tmp/music.ffconcat"
AUDIO_INPUT_ARGS=()
AUDIO_FILTER_ARGS=()

if [ -d "${MUSIC_DIR}" ]; then
  mapfile -t TRACKS < <(find "${MUSIC_DIR}" -type f \( -iname "*.mp3" \) 2>/dev/null | shuf || true)
else
  TRACKS=()
fi

if [ "${#TRACKS[@]}" -gt 0 ]; then
  echo "[renderer] Found ${#TRACKS[@]} mp3 file(s) in ${MUSIC_DIR}. Building shuffled playlist..."
  {
    echo "ffconcat version 1.0"
    for f in "${TRACKS[@]}"; do
      # ffconcat needs paths quoted; escape single quotes
      esc="${f//\'/\'\\\'\'}"
      echo "file '${esc}'"
    done
  } > "${PLAYLIST}"

  # -re so audio is paced in real time
  AUDIO_INPUT_ARGS=(-re -stream_loop -1 -f concat -safe 0 -i "${PLAYLIST}")
else
  echo "[renderer] No mp3 files found in ${MUSIC_DIR}. Using silent audio."
  AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000")
fi

# Optional gain
if [ "${AUDIO_GAIN_DB}" != "0" ] && [ "${AUDIO_GAIN_DB}" != "0.0" ]; then
  AUDIO_FILTER_ARGS=(-af "volume=${AUDIO_GAIN_DB}dB")
fi

# --- Choose video encoder (NEW) ---
pick_encoder() {
  if [ "${VIDEO_ENCODER}" = "auto" ]; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^[[:space:]]*V.*h264_nvenc'; then
      echo "h264_nvenc"
    elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^[[:space:]]*V.*h264_qsv'; then
      echo "h264_qsv"
    elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^[[:space:]]*V.*h264_vaapi'; then
      echo "h264_vaapi"
    else
      echo "libx264"
    fi
  else
    echo "${VIDEO_ENCODER}"
  fi
}

ENC="$(pick_encoder)"
echo "[renderer] Video encoder selected: ${ENC}"

VENC_ARGS=()
EXTRA_HW_INPUT_ARGS=()

if [ "${ENC}" = "h264_nvenc" ]; then
  VENC_ARGS=(-c:v h264_nvenc -preset "${NVENC_PRESET}" -profile:v "${NVENC_PROFILE}" -rc "${NVENC_RC}")
elif [ "${ENC}" = "h264_qsv" ]; then
  # QSV often needs a device; simplest is to allow it to pick, but /dev/dri must exist in container
  VENC_ARGS=(-c:v h264_qsv -global_quality 23 -look_ahead 0)
elif [ "${ENC}" = "h264_vaapi" ]; then
  # VAAPI usually requires an explicit device and hwupload path. This is a best-effort default.
  # You MUST mount /dev/dri into the container for this to work.
  EXTRA_HW_INPUT_ARGS=(-vaapi_device "${VAAPI_DEVICE}")
  # Convert to NV12 then upload to VAAPI:
  VF="format=nv12,hwupload,${VF}"
  VENC_ARGS=(-c:v h264_vaapi)
else
  VENC_ARGS=(-c:v libx264 -preset "${X264_PRESET}" -tune zerolatency)
fi

echo "[renderer] Starting FFmpeg capture -> http://0.0.0.0:${STREAM_PORT}/stream.ts"
echo "[renderer] Capture: ${W}x${H} @ ${FPS}fps, v_bitrate=${BITRATE}, crop_y=${CROP_Y}, music_dir=${MUSIC_DIR}"

# Inputs:
#   0: x11grab video
#   1: music (concat loop) OR silence generator
DISPLAY="${DISPLAY}" ffmpeg -hide_banner -loglevel info \
  -fflags nobuffer -flags low_delay \
  ${EXTRA_HW_INPUT_ARGS[@]+"${EXTRA_HW_INPUT_ARGS[@]}"} \
  -f x11grab -draw_mouse 0 -video_size "${W}x${H}" -framerate "${FPS}" -i "${DISPLAY}.0+0,0" \
  "${AUDIO_INPUT_ARGS[@]}" \
  -vf "${VF}" \
  "${AUDIO_FILTER_ARGS[@]}" \
  "${VENC_ARGS[@]}" \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -b:v "${BITRATE}" -maxrate "${BITRATE}" -bufsize 7000k \
  -c:a aac -b:a "${AUDIO_BITRATE}" -ac 2 -ar 48000 \
  -muxdelay 0 -muxpreload 0 \
  -f mpegts -listen 1 "http://0.0.0.0:${STREAM_PORT}/stream.ts" &
FFMPEG_PID="$!"

wait "${FFMPEG_PID}"
