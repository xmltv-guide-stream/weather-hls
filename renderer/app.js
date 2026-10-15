// Browser supervisor: keeps one Chromium window showing TARGET_URL on the Xvfb display,
// forever. FFmpeg captures the display independently, so nothing here can stop the stream:
// a crash or hang only costs a few seconds of picture while Chromium is relaunched.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer-core";

const env = (k, d) => process.env[k] ?? d;
const num = (k, d) => {
  const v = parseFloat(env(k, ""));
  return Number.isFinite(v) ? v : d;
};

const TARGET_URL = env("TARGET_URL", "https://v2.weatherscan.net/?90210");
const W = num("VIEWPORT_W", 1280);
const H = num("VIEWPORT_H", 720);
const HEALTH_PORT = num("HEALTH_PORT", 3001);
const USER_DATA_DIR = env("USER_DATA_DIR", "/tmp/chrome-profile");
const CHROMIUM = env("CHROMIUM_PATH", "/usr/bin/chromium");
const PAGE_AUDIO = env("AUDIO_SOURCE", "music") === "page";
const HLS_PLAYLIST = env("HLS_PLAYLIST", "/hls/weather.m3u8");

// Refresh the page this often to shed memory leaks (0 = never). Done as a background-tab
// swap, so viewers never see a blank/loading page.
const REFRESH_HOURS = num("REFRESH_HOURS", 6);
// Fully relaunch Chromium this often, and/or when its total RSS passes a limit (0 = off).
const RELAUNCH_HOURS = num("RELAUNCH_HOURS", 24);
const MAX_BROWSER_MB = num("MAX_BROWSER_MB", 2500);
// Swap the page early if its JS heap grows past this.
const MAX_HEAP_MB = num("MAX_HEAP_MB", 600);
// How long a freshly loaded background tab gets to fetch data before it goes on air.
const SWAP_WARMUP_S = num("SWAP_WARMUP_S", 8);
// Cap the page's requestAnimationFrame rate (0 = uncapped). Defaults to the capture rate.
const PAGE_MAX_FPS = num("PAGE_MAX_FPS", num("CAPTURE_FPS", 30));

const WATCHDOG_MS = 15000;
const PROBE_TIMEOUT_MS = 10000;
const MAX_PROBE_FAILS = 3;

const state = {
  status: "starting",
  startedAt: new Date().toISOString(),
  browserLaunches: 0,
  pageSwaps: 0,
  lastPageLoad: null,
  lastError: null,
  jsHeapMB: null,
  browserMemMB: null,
};

let browser = null;
let page = null;
let launchedAt = 0;
let loadedAt = 0;
let probeFails = 0;
let busy = false;
let pageCrashed = false;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(`[browser ${new Date().toISOString()}]`, ...a);

function withTimeout(promise, ms, what) {
  let t;
  return Promise.race([
    promise.finally(() => clearTimeout(t)),
    new Promise((_, rej) => (t = setTimeout(() => rej(new Error(`${what} timed out after ${ms}ms`)), ms))),
  ]);
}

// Page console output is useful for debugging but can be very chatty over days of uptime;
// cap it so it can never flood the container logs.
const logBudget = { windowStart: Date.now(), count: 0, dropped: 0 };
function pageLog(line) {
  const now = Date.now();
  if (now - logBudget.windowStart > 60000) {
    if (logBudget.dropped) log(`(suppressed ${logBudget.dropped} page log lines in the last minute)`);
    logBudget.windowStart = now;
    logBudget.count = 0;
    logBudget.dropped = 0;
  }
  if (++logBudget.count > 20) {
    logBudget.dropped++;
    return;
  }
  log(line.length > 500 ? line.slice(0, 500) + "…" : line);
}

function chromiumArgs() {
  const args = [
    `--user-data-dir=${USER_DATA_DIR}`,
    `--window-size=${W},${H}`,
    "--window-position=0,0",
    "--kiosk",
    "--force-device-scale-factor=1",
    "--no-first-run",
    "--no-default-browser-check",
    "--no-sandbox",
    // Suppresses the "unsupported command-line flag: --no-sandbox" infobar, which is what
    // previously had to be cropped off the top of the capture.
    "--test-type",
    "--noerrdialogs",
    "--hide-crash-restore-bubble",
    "--password-store=basic",
    "--hide-scrollbars",
    "--autoplay-policy=no-user-gesture-required",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    "--disable-features=Translate,MediaRouter,OptimizationHints,CalculateNativeWinOcclusion",
    // The radar/maps are WebGL (maplibre/mapbox-gl). There is no GPU in Xvfb, and current
    // Chromium no longer falls back to SwiftShader for WebGL unless explicitly allowed.
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
    // ...but only for WebGL. With SwiftShader enabled Chromium would otherwise also raster
    // and composite the whole page through emulated GL, which costs several CPU cores.
    // Skia's native CPU paths are far cheaper for everything that isn't a WebGL canvas.
    "--disable-gpu-rasterization",
    "--disable-gpu-compositing",
    "--disable-accelerated-2d-canvas",
    `--disk-cache-dir=${path.join(USER_DATA_DIR, "cache")}`,
    `--disk-cache-size=${64 * 1024 * 1024}`,
    "--log-level=3",
  ];
  // When the soundtrack comes from local files, nothing should play inside the browser.
  if (!PAGE_AUDIO) args.push("--mute-audio");
  return args;
}

function removeProfileLocks() {
  for (const f of ["SingletonLock", "SingletonSocket", "SingletonCookie"]) {
    try {
      fs.rmSync(path.join(USER_DATA_DIR, f), { force: true });
    } catch {}
  }
}

// Memory of the browser process and all its descendants (renderer, GPU, utility processes).
// Uses PSS rather than RSS: Chromium's processes share a lot of memory, and summing RSS
// counts it once per process, overstating real usage by ~50%.
function browserMemMB() {
  const pid = browser?.process()?.pid;
  if (!pid) return null;
  const children = new Map();
  for (const d of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(d)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${d}/stat`, "utf8");
      const ppid = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      if (!children.has(ppid)) children.set(ppid, []);
      children.get(ppid).push(Number(d));
    } catch {}
  }
  let kb = 0;
  const stack = [pid];
  while (stack.length) {
    const p = stack.pop();
    try {
      const m = fs.readFileSync(`/proc/${p}/smaps_rollup`, "utf8").match(/^Pss:\s+(\d+)/m);
      if (m) kb += Number(m[1]);
    } catch {}
    stack.push(...(children.get(p) || []));
  }
  return Math.round(kb / 1024);
}

async function preparePage(p) {
  // Hold page audio until this tab is on air, so a background swap never plays two
  // soundtracks at once.
  await p.evaluateOnNewDocument((maxFps) => {
    window.__wxHold = true;
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (...a) {
      if (window.__wxHold) this.muted = true;
      return play.apply(this, a);
    };

    // Chromium runs requestAnimationFrame at 60Hz, but the capture only takes FPS frames a
    // second. Rendering the in-between frames (mostly the WebGL maps, in software) is pure
    // waste, so batch rAF callbacks down to the capture rate.
    if (!(maxFps > 0)) return;
    const interval = 1000 / maxFps - 2; // small slack so 60Hz vsync lands on every other frame
    const nativeRAF = window.requestAnimationFrame.bind(window);
    let queued = new Map();
    let running = null;
    let nextId = 0;
    let pumping = false;
    let last = 0;
    const pump = (t) => {
      if (t - last < interval) {
        nativeRAF(pump);
        return;
      }
      last = t;
      pumping = false;
      running = queued;
      queued = new Map();
      for (const cb of running.values()) {
        try {
          cb(t);
        } catch (e) {
          setTimeout(() => {
            throw e;
          });
        }
      }
      running = null;
    };
    window.requestAnimationFrame = (cb) => {
      const id = ++nextId;
      queued.set(id, cb);
      if (!pumping) {
        pumping = true;
        nativeRAF(pump);
      }
      return id;
    };
    window.cancelAnimationFrame = (id) => {
      queued.delete(id);
      running?.delete(id);
    };
  }, PAGE_MAX_FPS);
  p.setDefaultNavigationTimeout(60000);

  p.on("framenavigated", (frame) => {
    if (frame === p.mainFrame()) log(`navigated: ${frame.url()}`);
  });
  p.on("console", (msg) => {
    const t = msg.type();
    if (t === "error" || t === "warn" || t === "warning") pageLog(`[page ${t}] ${msg.text()}`);
  });
  p.on("pageerror", (err) => pageLog(`[page error] ${err?.message || err}`));
  p.on("requestfailed", (req) => {
    const err = req.failure()?.errorText || "";
    if (err !== "net::ERR_ABORTED") pageLog(`[request failed] ${req.url()} ${err}`);
  });
  p.on("dialog", (d) => d.dismiss().catch(() => {}));
  p.on("error", (err) => {
    // Renderer process crashed ("Page crashed!").
    if (p === page) {
      log("page crashed:", err?.message || err);
      pageCrashed = true;
    }
  });
}

async function goOnAir(p) {
  await p.bringToFront();
  await p.evaluate(() => {
    window.__wxHold = false;
    document.querySelectorAll("audio,video").forEach((m) => (m.muted = false));
  });
}

async function killBrowser() {
  const b = browser;
  browser = null;
  page = null;
  if (!b) return;
  const proc = b.process();
  try {
    await withTimeout(b.close(), 5000, "browser.close");
  } catch {
    try {
      proc?.kill("SIGKILL");
    } catch {}
  }
}

async function launchBrowser() {
  await killBrowser();
  removeProfileLocks();
  state.status = "launching";
  state.browserLaunches++;
  log(`launching Chromium (#${state.browserLaunches}) -> ${TARGET_URL}`);

  const b = await puppeteer.launch({
    headless: false,
    executablePath: CHROMIUM,
    defaultViewport: null, // use the real window size, which equals the Xvfb screen
    ignoreDefaultArgs: ["--enable-automation"],
    args: chromiumArgs(),
    handleSIGINT: false,
    handleSIGTERM: false,
    handleSIGHUP: false,
    protocolTimeout: 60000,
  });
  // Drain Chromium's stdio; an unread pipe that fills up will eventually block the browser.
  b.process()?.stdout?.resume();
  b.process()?.stderr?.resume();

  browser = b;
  launchedAt = Date.now();
  probeFails = 0;
  b.on("disconnected", () => {
    if (browser === b) {
      log("Chromium disconnected");
      browser = null;
      page = null;
    }
  });

  const p = (await b.pages())[0] || (await b.newPage());
  await preparePage(p);
  page = p;
  pageCrashed = false;
  await p.goto(TARGET_URL, { waitUntil: "domcontentloaded" });
  await goOnAir(p);
  loadedAt = Date.now();
  state.lastPageLoad = new Date().toISOString();
  state.status = "running";
}

// Load a fresh copy of the page in a hidden tab, give it time to fetch its data, then cut
// over to it and close the old tab (which frees that renderer process and its leaks).
async function swapPage(reason) {
  log(`refreshing page (${reason})`);
  const b = browser;
  const old = page;
  const marker = `about:blank#wx-${Date.now()}`;
  const session = await b.target().createCDPSession();
  try {
    await session.send("Target.createTarget", { url: marker, background: true });
  } finally {
    await session.detach().catch(() => {});
  }
  const target = await b.waitForTarget((t) => t.url() === marker, { timeout: 15000 });
  const fresh = await target.page();
  try {
    await preparePage(fresh);
    await fresh.goto(TARGET_URL, { waitUntil: "load" });
    await sleep(SWAP_WARMUP_S * 1000);
    await goOnAir(fresh);
  } catch (e) {
    await fresh.close().catch(() => {});
    throw e;
  }
  page = fresh;
  pageCrashed = false;
  loadedAt = Date.now();
  state.pageSwaps++;
  state.lastPageLoad = new Date().toISOString();
  await old?.close().catch(() => {});
}

async function probe() {
  // A cheap round-trip into the page's main thread; fails if the renderer is hung.
  return withTimeout(
    page.evaluate(() => document.readyState),
    PROBE_TIMEOUT_MS,
    "page probe"
  );
}

async function tick() {
  if (busy) return;
  busy = true;
  try {
    if (!browser || !browser.connected || !page || page.isClosed()) {
      await launchBrowser();
      return;
    }

    try {
      await probe();
      probeFails = 0;
    } catch (e) {
      probeFails++;
      log(`probe failed (${probeFails}/${MAX_PROBE_FAILS}): ${e.message}`);
    }

    state.browserMemMB = browserMemMB();
    try {
      const m = await withTimeout(page.metrics(), PROBE_TIMEOUT_MS, "metrics");
      state.jsHeapMB = Math.round(m.JSHeapUsedSize / 1048576);
    } catch {}

    const now = Date.now();
    if (probeFails >= MAX_PROBE_FAILS) {
      await launchBrowser();
    } else if (RELAUNCH_HOURS > 0 && now - launchedAt > RELAUNCH_HOURS * 3600e3) {
      log("scheduled Chromium relaunch");
      await launchBrowser();
    } else if (MAX_BROWSER_MB > 0 && state.browserMemMB > MAX_BROWSER_MB) {
      log(`Chromium using ${state.browserMemMB}MB (limit ${MAX_BROWSER_MB}MB), relaunching`);
      await launchBrowser();
    } else if (pageCrashed) {
      await swapPage("renderer crashed");
    } else if (MAX_HEAP_MB > 0 && state.jsHeapMB > MAX_HEAP_MB) {
      await swapPage(`JS heap ${state.jsHeapMB}MB > ${MAX_HEAP_MB}MB`);
    } else if (REFRESH_HOURS > 0 && now - loadedAt > REFRESH_HOURS * 3600e3) {
      await swapPage("scheduled");
    }
  } catch (e) {
    state.lastError = `${new Date().toISOString()} ${e?.message || e}`;
    log("error:", e?.message || e);
    // A failed launch, or a browser that died mid-action, is torn down so the next tick
    // starts clean. A failed refresh leaves the current page on air untouched.
    if (state.status !== "running" || !browser?.connected || !page || page.isClosed()) {
      state.status = "recovering";
      await killBrowser();
    }
  } finally {
    busy = false;
  }
}

function hlsAgeSeconds() {
  try {
    return Math.round((Date.now() - fs.statSync(HLS_PLAYLIST).mtimeMs) / 1000);
  } catch {
    return null;
  }
}

http
  .createServer((req, res) => {
    if (req.url !== "/health") {
      res.writeHead(404).end();
      return;
    }
    const hlsAge = hlsAgeSeconds();
    const ok = state.status === "running" && hlsAge !== null && hlsAge < 30;
    res.writeHead(ok ? 200 : 503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok, target: TARGET_URL, viewport: `${W}x${H}`, hlsAgeSeconds: hlsAge, ...state }));
  })
  .listen(HEALTH_PORT, () => log(`health on :${HEALTH_PORT}/health`));

process.on("SIGTERM", async () => {
  await killBrowser();
  process.exit(0);
});

tick();
setInterval(tick, WATCHDOG_MS);
