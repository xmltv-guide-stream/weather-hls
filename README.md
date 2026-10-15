# weather-hls

Turn a dynamic weather webpage (default: the Weatherscan simulator at
`https://v2.weatherscan.net/?90210`) into a **live HLS stream** for IPTV players, using Docker.

Chromium renders the page on a virtual display (Xvfb), FFmpeg captures that display and
writes HLS segments to an in-memory volume, and nginx serves them together with an M3U
playlist and XMLTV guide.

```text
renderer:  Xvfb ── Chromium (supervised by app.js)
             │         └─ page audio ─> PulseAudio null sink ─┐
             └─ x11grab ─> FFmpeg (NVENC / QSV / VAAPI / x264) ┴─> /hls  (tmpfs volume)
web:       nginx  /weather.m3u8 + segments (from /hls), /playlist.m3u + /guide.xml (from ./output)
xmltv:     writes playlist.m3u + guide.xml to ./output
```

## Quick start

```bash
docker compose up -d --build
```

Then play `http://<host>:9798/weather.m3u8`, or add `http://<host>:9798/playlist.m3u`
(with guide `http://<host>:9798/guide.xml`) to your IPTV app.

The compose file reserves an NVIDIA GPU for hardware encoding. **On a host without an NVIDIA
GPU, delete the `deploy:` block**, or the container will not start; the encoder then falls back
automatically.

## Stability design

- **Capture never depends on the browser.** FFmpeg records the X display, not the page, so a
  Chromium crash or relaunch only shows a few seconds of black. The stream keeps going.
- **Every process self-heals.** `start.sh` restarts the browser supervisor, encoder and music
  feeder whenever any of them exits, and restarts the encoder if the playlist stops updating.
  `app.js` relaunches Chromium if it crashes, disconnects, or stops responding to a probe.
- **Memory leaks are flushed.** Every `REFRESH_HOURS` (or early, if the page's JS heap passes
  `MAX_HEAP_MB`), a fresh copy of the page loads in a hidden tab and is cut to once it's
  ready, so viewers never see a blank loading page. Chromium is fully relaunched every
  `RELAUNCH_HOURS`, or when it passes `MAX_BROWSER_MB`.
- **Encoder restarts are seamless for players.** Segment numbering continues and a
  discontinuity tag is inserted.
- **Bounded resources.** HLS lives in a 256 MB tmpfs (no disk churn), the capture queue is
  small, docker logs are size-capped, and page console output is rate-limited.

## Configuration (renderer)

| Variable | Default | Description |
|---|---|---|
| `TARGET_URL` | `https://v2.weatherscan.net/?90210` | Page to render |
| `VIEWPORT_W` / `VIEWPORT_H` | `1280` / `720` | Display and output size |
| `CAPTURE_FPS` | `30` | Capture frame rate (the page's animation rate is capped to match) |
| `VIDEO_BITRATE` | `3500k` | Maximum video bitrate (quality-capped VBR; static scenes use less) |
| `VIDEO_ENCODER` | `auto` | `auto` tests `h264_nvenc`, `h264_qsv`, `h264_vaapi` and falls back to `libx264` |
| `CROP_Y` | `0` | Crop pixels from the top; output is scaled back to the full size |
| `AUDIO_SOURCE` | `page` | `page` = the site's own music and narrations, `music` = shuffled files from `./music`, `none` = silence |
| `MUSIC_DIR` | `/music` | Music folder (mp3/m4a/aac/ogg/flac/wav), used when `AUDIO_SOURCE=music` |
| `AUDIO_BITRATE` / `AUDIO_GAIN_DB` | `128k` / `0` | AAC bitrate and gain |
| `REFRESH_HOURS` | `6` | Seamless page refresh interval (`0` = off) |
| `RELAUNCH_HOURS` | `24` | Full Chromium relaunch interval (`0` = off) |
| `MAX_BROWSER_MB` | `2500` | Relaunch Chromium if its memory (PSS) exceeds this |
| `MAX_HEAP_MB` | `600` | Refresh the page early if its JS heap exceeds this |
| `HLS_TIME` / `HLS_LIST_SIZE` | `4` / `8` | Segment length (s) and playlist length |

## Monitoring

`http://<host>:8081/health` returns JSON with the browser status, launch and refresh counts,
memory, and the playlist age. It responds `503` when the stream is stale, which also drives the
container's Docker health check.

```bash
docker compose logs -f renderer
```

## Notes

- The radar and maps are WebGL. There is no GPU inside Xvfb, so Chromium uses SwiftShader
  (software GL) for WebGL canvases only. Everything else uses Chromium's much cheaper CPU
  raster and compositing paths. The maps are still the largest CPU cost: the page stacks
  several separate map instances, each with its own WebGL context.
- `renderer_profile` is an optional seed: anything in it is copied into a fresh Chromium
  profile at container start.

## License

MIT.
