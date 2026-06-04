import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";

const GEO_TOKENS_KEY = "geo.tokens";
const GEO_LAST_IP_KEY = "geo.lastIp";
const GEO_CHECKED_AT_KEY = "geo.checkedAt";
const GEO_LAST_RELOAD_AT_KEY = "geo.lastReloadAt";

const GEO_TTL_MS = 6 * 60 * 60 * 1000; // 6h
const GEO_POLL_INTERVAL_MS = 0; // set >0 to enable periodic checks
const GEO_RELOAD_MIN_INTERVAL_MS = 60 * 1000; // 60s

const IPINFO_URL = "https://ipinfo.io/json";

function nowMs() {
  return Date.now ? Date.now() : new Date().getTime();
}

function shouldCheckAgain() {
  const last = parseInt(localStorage.getItem(GEO_CHECKED_AT_KEY) || "0", 10);
  if (!last) {
    return true;
  }
  return nowMs() - last >= GEO_TTL_MS;
}

function tokenizePieces(...parts) {
  const out = new Set();
  for (const p of parts) {
    const clean = (p || "").toString().trim();
    if (!clean) {
      continue;
    }
    const low = clean.toLowerCase();
    out.add(low);
    out.add(low.replace(/\s+/g, "-")); // "north york" -> "north-york"
  }
  return Array.from(out);
}

function tokensChanged(newCsv) {
  const prev = (localStorage.getItem(GEO_TOKENS_KEY) || "").trim();
  return prev !== (newCsv || "").trim();
}

function dispatchGeoUpdated() {
  try {
    window.dispatchEvent(new CustomEvent("rr-geo-updated"));
  } catch {
    /* no-op */
  }
}

function hardReloadIfAllowed({ enabled = true } = {}) {
  if (!enabled) {
    return;
  }
  if (document.visibilityState !== "visible") {
    return;
  }
  const last = parseInt(
    localStorage.getItem(GEO_LAST_RELOAD_AT_KEY) || "0",
    10
  );
  if (nowMs() - last < GEO_RELOAD_MIN_INTERVAL_MS) {
    return;
  }
  localStorage.setItem(GEO_LAST_RELOAD_AT_KEY, String(nowMs()));
  window.location.reload();
}

// v0.3.0: previously this hit /session/current.json then /site.json. Both 403
// under WAF rate-limiting on home.renovation.reviews and contributed to the
// 403 storm. The plugin already exposes client_ip via add_to_serializer
// for staff -- read it from currentUser if available, otherwise from the
// preloaded data island. Either path is zero-fetch.
function fetchSessionIp(api) {
  try {
    const u = api?.getCurrentUser?.();
    if (u && u.client_ip) return u.client_ip;
    // Read preloaded `currentUser.client_ip` if the global isn't populated yet
    const el = document.getElementById("data-preloaded");
    if (!el) return null;
    const raw = el.getAttribute("data-preloaded");
    if (!raw) return null;
    const outer = JSON.parse(raw);
    let cu = outer.currentUser;
    if (typeof cu === "string") { try { cu = JSON.parse(cu); } catch { cu = null; } }
    return (cu && cu.client_ip) || null;
  } catch {
    return null;
  }
}

async function fetchIpinfo() {
  const res = await fetch(IPINFO_URL, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) {
    throw new Error(`ipinfo ${res.status}`);
  }
  // { ip, city, region, country, ... }
  return res.json();
}

async function updateProfileLocation(
  api,
  { city, region, onlyIfBlank = true }
) {
  const currentUser = api.getCurrentUser?.();
  if (!currentUser) {
    return;
  }
  if (onlyIfBlank && currentUser.location) {
    return;
  }

  const loc = city && region ? `${city}, ${region}` : city || region || "";
  if (!loc) {
    return;
  }

  try {
    await ajax(`/u/${encodeURIComponent(currentUser.username)}.json`, {
      type: "PUT",
      data: { location: loc },
    });
    currentUser.location = loc;
  } catch {}
}

function hasProfileLocation(api) {
  const currentUser = api.getCurrentUser?.();
  return !!currentUser?.location;
}

function setDefaultTokensIfMissing() {
  if ((localStorage.getItem(GEO_TOKENS_KEY) || "").trim()) {
    return;
  }
  localStorage.setItem(GEO_TOKENS_KEY, "toronto,gta,ontario,canada");
}

async function bootstrapFromIpinfo(api, { persistIp }) {
  const j = await fetchIpinfo();
  const city = j?.city;
  const region = j?.region;
  const country = j?.country;

  const toks = tokenizePieces(city, region, country).filter(Boolean);
  const csv = toks.length ? toks.join(",") : "toronto,gta,ontario,canada";

  if (tokensChanged(csv)) {
    localStorage.setItem(GEO_TOKENS_KEY, csv);
    dispatchGeoUpdated();
  }
  await updateProfileLocation(api, { city, region, onlyIfBlank: true });

  if (persistIp) {
    localStorage.setItem(GEO_LAST_IP_KEY, persistIp || j?.ip || "");
  }
}

async function refreshGeoIfNeeded(api, { force = false } = {}) {
  if (!force && !shouldCheckAgain()) {
    return;
  }

  setDefaultTokensIfMissing();

  const sessionIp = fetchSessionIp(api);
  const lastIp = localStorage.getItem(GEO_LAST_IP_KEY) || "";
  const firstRun = !lastIp;
  const ipChanged = sessionIp && lastIp && sessionIp !== lastIp;

  const needsBootstrap = !hasProfileLocation(api);
  if (needsBootstrap || ipChanged || firstRun || force) {
    try {
      await bootstrapFromIpinfo(api, { persistIp: sessionIp });
      if (ipChanged && !firstRun) {
        hardReloadIfAllowed({
          enabled: true,
        });
      }
    } catch {
      if (!(localStorage.getItem(GEO_TOKENS_KEY) || "").trim()) {
        localStorage.setItem(GEO_TOKENS_KEY, "toronto,gta,ontario,canada");
        dispatchGeoUpdated();
      }
    }
  } else if (sessionIp && firstRun) {
    // runs on init?
    localStorage.setItem(GEO_LAST_IP_KEY, sessionIp);
  }

  localStorage.setItem(GEO_CHECKED_AT_KEY, String(nowMs()));
}

export default {
  name: "geo-ipinfo",
  initialize() {
    withPluginApi(async (api) => {
      const ss = api.container.lookup("service:site-settings");
      if (!ss?.rr_geo_enabled) {
        return;
      }
      await refreshGeoIfNeeded(api, { force: true });

      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible") {
          refreshGeoIfNeeded(api);
        }
      });
      window.addEventListener("online", () => refreshGeoIfNeeded(api));

      // v0.3.0: when the user updates their location via the feed widget,
      // re-tokenize immediately so search/feed prioritization picks up the
      // new place without waiting for the next visibility cycle.
      window.addEventListener("rr-geo-updated", (e) => {
        const newLoc = (e && e.detail && e.detail.location) || "";
        if (newLoc) {
          const toks = tokenizePieces(newLoc);
          if (toks.length) {
            const csv = toks.join(",");
            if (tokensChanged(csv)) {
              localStorage.setItem(GEO_TOKENS_KEY, csv);
            }
          }
        } else {
          // Cleared -- reset to defaults so prioritization falls back gracefully
          localStorage.setItem(GEO_TOKENS_KEY, "toronto,gta,ontario,canada");
        }
      });

      if (GEO_POLL_INTERVAL_MS > 0) {
        setInterval(() => refreshGeoIfNeeded(api), GEO_POLL_INTERVAL_MS);
      }
    });
  },
};
