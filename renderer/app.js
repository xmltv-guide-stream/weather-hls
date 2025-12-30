import express from "express";
import puppeteer from "puppeteer-core";

const TARGET_URL = process.env.TARGET_URL || "https://v2.weatherscan.net/?90210";
const W = parseInt(process.env.VIEWPORT_W || "1280", 10);
const H = parseInt(process.env.VIEWPORT_H || "720", 10);
const HEALTH_PORT = parseInt(process.env.HEALTH_PORT || "3001", 10);
const USER_DATA_DIR = process.env.USER_DATA_DIR || "/profile";

const USER_AGENT =
  process.env.USER_AGENT ||
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

let lastErr = null;
let started = false;
let navCount = 0;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function launch() {
  const host = (() => {
    try {
      return new URL(TARGET_URL).hostname;
    } catch {
      return "";
    }
  })();

  const browser = await puppeteer.launch({
    headless: false,
    executablePath: "/usr/bin/chromium",
    ignoreDefaultArgs: ["--enable-automation"],
    args: [
      `--user-data-dir=${USER_DATA_DIR}`,
      `--app=${TARGET_URL}`,              // app-mode (no URL bar)
      `--window-size=${W},${H}`,
      "--window-position=0,0",
      "--kiosk",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-infobars",
      "--disable-dev-shm-usage",
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-gpu",
      "--disable-features=Translate,BackForwardCache",
      "--autoplay-policy=no-user-gesture-required",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-renderer-backgrounding",
      "--use-gl=swiftshader",
      "--hide-scrollbars",
    ],
  });

  // Prefer the app window's page if it exists
  let page = null;

  // Give Chromium a moment to spawn targets
  await sleep(1500);

  // Try to find a page whose URL matches the target host (dynamic)
  if (host) {
    try {
      const target = await browser.waitForTarget(
        (t) => {
          const url = t.url() || "";
          return t.type() === "page" && url.includes(host);
        },
        { timeout: 15000 }
      );
      page = await target.page();
    } catch {
      // ignore; we'll fall back below
    }
  }

  // Fall back: use the first page the browser knows about
  if (!page) {
    const pages = await browser.pages();
    page = pages?.[0] || (await browser.newPage());
  }

  if (!page) throw new Error("Failed to acquire a Puppeteer page");

  // Stealth-ish tweaks must be set BEFORE navigation
  await page.evaluateOnNewDocument(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
    Object.defineProperty(navigator, "languages", { get: () => ["en-US", "en"] });
    Object.defineProperty(navigator, "plugins", { get: () => [1, 2, 3, 4, 5] });
    window.chrome = window.chrome || { runtime: {} };

    const originalQuery = window.navigator.permissions?.query;
    if (originalQuery) {
      window.navigator.permissions.query = (parameters) =>
        parameters.name === "notifications"
          ? Promise.resolve({ state: Notification.permission })
          : originalQuery(parameters);
    }
  });

  await page.setUserAgent(USER_AGENT);
  await page.setExtraHTTPHeaders({ "Accept-Language": "en-US,en;q=0.9" });
  await page.setViewport({ width: W, height: H });
  page.setDefaultNavigationTimeout(120000);

  // Debug: if it’s “refreshing”, you’ll see it here
  page.on("framenavigated", (frame) => {
    if (frame === page.mainFrame()) {
      navCount++;
      console.log(`[renderer] NAV ${navCount}: ${frame.url()}`);
    }
  });

  page.on("console", (msg) => {
    console.log(`[page console:${msg.type()}] ${msg.text()}`);
  });

  page.on("pageerror", (err) => {
    console.log("[page error]", err?.stack || String(err));
  });

  page.on("requestfailed", (req) => {
    console.log("[request failed]", req.url(), req.failure()?.errorText);
  });

  // Even in --app mode, force a clean navigation to ensure we’re at TARGET_URL
  await page.goto(TARGET_URL, { waitUntil: "domcontentloaded" });

  // Let JS-heavy pages settle
  await sleep(12000);

  // Kick lazy loaders once
  await page.evaluate(() => {
    window.scrollTo(0, 1);
    window.scrollTo(0, 0);
  });

  await sleep(8000);

  started = true;
}

const app = express();
app.get("/health", (req, res) => {
  res.json({
    ok: started,
    target: TARGET_URL,
    viewport: `${W}x${H}`,
    navCount,
    lastErr,
  });
});

app.listen(HEALTH_PORT, () => {
  console.log(`Health listening on :${HEALTH_PORT}`);
  console.log("Target:", TARGET_URL);
});

launch().catch((e) => {
  lastErr = String(e?.stack || e);
  console.error("Fatal:", e);
  process.exit(1);
});
