import os
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import xml.etree.ElementTree as ET

TZ = os.environ.get("TZ", "America/Chicago")
CHANNEL_ID = os.environ.get("CHANNEL_ID", "local.weather")
CHANNEL_NAME = os.environ.get("CHANNEL_NAME", "Local Weather")
GUIDE_DAYS = int(os.environ.get("GUIDE_DAYS", "2"))

OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/output")
STREAM_URL = os.environ.get("STREAM_URL", "weather.m3u8")
M3U_NAME = os.environ.get("M3U_NAME", "playlist.m3u")
XMLTV_NAME = os.environ.get("XMLTV_NAME", "guide.xml")

def xmltv_dt(dt: datetime) -> str:
  # XMLTV time format: YYYYMMDDHHMMSS +/-ZZZZ
  # We'll emit local time with offset.
  off = dt.utcoffset()
  sign = "+" if off and off.total_seconds() >= 0 else "-"
  secs = abs(int(off.total_seconds())) if off else 0
  hh = secs // 3600
  mm = (secs % 3600) // 60
  return dt.strftime("%Y%m%d%H%M%S") + f" {sign}{hh:02d}{mm:02d}"

def hour_label(dt: datetime) -> str:
  # "Local Weather @ 4PM"
  return dt.strftime("Local Weather @ %-I%p").replace("AM", "AM").replace("PM", "PM")

def write_xmltv(now: datetime):
  tv = ET.Element("tv")
  tv.set("generator-info-name", "dummy-xmltv-generator")

  ch = ET.SubElement(tv, "channel", id=CHANNEL_ID)
  dn = ET.SubElement(ch, "display-name")
  dn.text = CHANNEL_NAME

  start = now.replace(minute=0, second=0, microsecond=0)
  end = start + timedelta(days=GUIDE_DAYS)

  t = start
  while t < end:
    p = ET.SubElement(tv, "programme")
    p.set("channel", CHANNEL_ID)
    p.set("start", xmltv_dt(t))
    p.set("stop", xmltv_dt(t + timedelta(hours=1)))

    title = ET.SubElement(p, "title", lang="en")
    title.text = hour_label(t)

    desc = ET.SubElement(p, "desc", lang="en")
    desc.text = "Automated local weather loop."

    t += timedelta(hours=1)

  tree = ET.ElementTree(tv)
  out_path = os.path.join(OUTPUT_DIR, XMLTV_NAME)
  ET.indent(tree, space="  ", level=0)
  tree.write(out_path, encoding="utf-8", xml_declaration=True)

def write_m3u():
  # A single-channel playlist that references the XMLTV.
  # Many IPTV apps read x-tvg-url from the top line.
  m3u = []
  m3u.append(f'#EXTM3U x-tvg-url="{XMLTV_NAME}"')
  m3u.append(f'#EXTINF:-1 tvg-id="{CHANNEL_ID}" tvg-name="{CHANNEL_NAME}" group-title="Local",{CHANNEL_NAME}')
  m3u.append(STREAM_URL)
  out_path = os.path.join(OUTPUT_DIR, M3U_NAME)
  with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(m3u) + "\n")

def main():
  os.makedirs(OUTPUT_DIR, exist_ok=True)
  zone = ZoneInfo(TZ)

  # Update immediately on start, then re-write periodically and at top-of-hour changes.
  while True:
    now = datetime.now(zone)
    write_xmltv(now)
    write_m3u()

    # Sleep 5 minutes; cheap + keeps guide “fresh” if you change GUIDE_DAYS, etc.
    time.sleep(300)

if __name__ == "__main__":
  main()
