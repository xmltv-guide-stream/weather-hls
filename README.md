# weather-hls

Turn a dynamic weather webpage into a **local HLS stream** (`weather.m3u8` + `.ts` segments) using Docker.  
This project launches Chromium in a virtual display (Xvfb), captures the rendered page as video via FFmpeg, and packages it into HLS. It can also **play shuffled MP3 background music on a continuous loop** (from a local `music/` folder).

---

## What this does

- Opens a target URL (default: `https://v2.weatherscan.net/?90210`) in Chromium (automated via Puppeteer).
- Renders it in Xvfb (no physical display required).
- Captures the rendered page at a fixed resolution/FPS.
- Optionally mixes in looping, randomized MP3 music from `./music`.
- Outputs a playable HLS stream:
  - `weather.m3u8`
  - `weather_00001.ts`, `weather_00002.ts`, ...

---

## Repo layout (typical)

```text
.
├─ docker-compose.yml
├─ renderer/
│  ├─ Dockerfile
│  ├─ app.js
│  └─ start.sh
├─ hls/
│  ├─ Dockerfile
│  └─ start.sh
├─ xmltv/
│  └─ (optional xmltv generator bits)
├─ output/                # bind-mounted output (HLS + xml/playlist)
└─ music/                 # drop mp3 files here (optional)
```

> Your exact structure may vary slightly — the intent is the same:
> renderer creates `stream.ts`, hls converts it to `weather.m3u8` + segments, output is served by the web container.

---

## Quick start

### 1) Create folders

From the repo root:

```bash
mkdir -p output music
```

On Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force output, music | Out-Null
```

### 2) Add MP3s (optional)

Put any `.mp3` files into:

- `./music`

If no MP3s are found, the stream will use silent audio.

### 3) Launch

```bash
docker compose up -d --build
```

### 4) Play the stream

Open in VLC (or any HLS-capable player):

- `http://<host>:<port>/weather.m3u8`

If you’re on the same machine and using the default compose ports, it’s commonly:

- `http://localhost:9798/weather.m3u8`

(Depends on how your `web` service is mapped.)

---

## Configuration

These are the most commonly used environment variables.

### Renderer (page capture)

| Variable | Default | Description |
|---|---:|---|
| `TARGET_URL` | `https://v2.weatherscan.net/?90210` | Webpage to render |
| `VIEWPORT_W` | `1280` | Capture width |
| `VIEWPORT_H` | `720` | Capture height |
| `CAPTURE_FPS` | `30` | Capture framerate |
| `VIDEO_BITRATE` | `3500k` | H.264 bitrate for the rendered capture |
| `CROP_Y` | `30` | Crop pixels from the top (removes window bar). Set `0` to disable |
| `USER_DATA_DIR` | `/profile` | Persisted Chrome profile location (usually a volume) |

### Music (renderer)

| Variable | Default | Description |
|---|---:|---|
| `MUSIC_DIR` | `/music` | Where MP3s are mounted in the container |
| `AUDIO_BITRATE` | `128k` | AAC bitrate |
| `AUDIO_GAIN_DB` | `0` | Optional audio gain in dB (e.g. `-6`, `3`) |

### HLS packager

| Variable | Default | Description |
|---|---:|---|
| `RENDERER_URL` | `http://renderer:3000/stream.ts` | Input TS from renderer |
| `OUTPUT_M3U8` | `/output/weather.m3u8` | Output playlist path |

---

## Notes / tips

### Segment storage (NVMe concerns)
HLS writes lots of small `.ts` files. Using NVMe is fine. If you want to reduce disk churn:

- keep a small `hls_list_size` (already set)
- use `delete_segments`
- consider putting only the *working* HLS directory on a faster disk and syncing out if needed

Using `/dev/shm` is possible on Linux but is usually not worth it for HLS segments unless you have plenty of RAM and you’re okay losing segments on restart.

### If the page is missing assets / looks broken
This usually happens when the automated browser is blocked or some resources are being denied. The renderer logs (`puppeteer.log`) will show console errors and failed requests.

### Headless vs headful
This project runs Chromium “headful” inside Xvfb so JavaScript-heavy sites behave more like a normal browser.

---

## Development

Rebuild after code changes:

```bash
docker compose build --no-cache
docker compose up -d
```

Tail logs:

```bash
docker compose logs -f
```

Renderer health endpoint:

- `http://localhost:<renderer-health-port>/health`

(Port depends on your compose mapping; internally it’s `3001`.)

---

## License

MIT.
