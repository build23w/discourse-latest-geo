import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";

const GEO_TOKENS_KEY = "geo.tokens";
const GEO_LAST_IP_KEY = "geo.lastIp";
const GEO_CHECKED_AT_KEY = "geo.checkedAt";
const GEO_LAST_RELOAD_AT_KEY = "geo.lastReloadAt";
const GEO_AUTOSET_KEY = "geo.autoset"; // marks a location WE auto-detected (safe to self-correct)

const GEO_TTL_MS = 6 * 60 * 60 * 1000; // 6h
const GEO_POLL_INTERVAL_MS = 0; // set >0 to enable periodic checks
const GEO_RELOAD_MIN_INTERVAL_MS = 60 * 1000; // 60s

const IPINFO_URL = "https://ipinfo.io/json";
// v0.15: the platform's own geolocation. On a Cloudflare-powered forum the
// edge answers this from request.cf (the fronting Worker replies without even
// waking Rails; a plain CF-proxied install serves it from the plugin reading
// the visitor-location headers). Same-origin, free, instant, and immune to
// the ad-blockers that eat ipinfo.io — so it is the default source, with
// ipinfo as the fallback wherever the platform can't answer.
const DETECT_URL = "/rr-geo/detect.json";

// v0.11: profile locations are structured "City, Province/State, Country".
// Both sources return ISO country codes; map the common ones, fall back to code.
const COUNTRY_NAMES = {
  CA: "Canada", US: "United States", GB: "United Kingdom", AU: "Australia",
  NZ: "New Zealand", IE: "Ireland", IN: "India", FR: "France", DE: "Germany",
};
let IPINFO_TOKEN = ""; // set from site settings at init (free tokens lift the anon limit)
let GEO_SOURCE = "auto"; // rr_geo_source: auto | cloudflare | ipinfo

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
  // Retained as a no-op (soft refresh only) — see ipChanged handler. A full
  // page reload to refresh geo ranking is far too heavy and caused double-loads.
  dispatchGeoUpdated();
  return;
  // eslint-disable-next-line no-unreachable
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
  const url = IPINFO_TOKEN ? `${IPINFO_URL}?token=${encodeURIComponent(IPINFO_TOKEN)}` : IPINFO_URL;
  const res = await fetch(url, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) {
    throw new Error(`ipinfo ${res.status}`);
  }
  // { ip, city, region, country, ... }
  return res.json();
}

async function fetchCloudflareGeo() {
  const res = await fetch(DETECT_URL, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) {
    throw new Error(`geo detect ${res.status}`);
  }
  const j = await res.json();
  if (!j || j.ok !== true) {
    throw new Error("geo detect: platform has no edge geolocation");
  }
  // { ok, source, ip (masked /24), city, region, region_code, country, timezone, postal }
  return j;
}

// Resolve { ip, city, region, country } from the configured source.
// "auto" (default): cloudflare first — SET BY THE PLATFORM whenever the forum
// runs behind Cloudflare — with ipinfo as the fallback; "cloudflare"/"ipinfo"
// pin one source.
async function resolveGeo() {
  if (GEO_SOURCE !== "ipinfo") {
    try {
      const j = await fetchCloudflareGeo();
      if ((j.city && j.region && j.country) || GEO_SOURCE === "cloudflare") {
        return { ip: j.ip, city: j.city, region: j.region, country: j.country };
      }
      // partial edge data in auto mode: let ipinfo try for the full triple
    } catch (e) {
      if (GEO_SOURCE === "cloudflare") {
        throw e;
      }
    }
  }
  const j = await fetchIpinfo();
  return { ip: j?.ip, city: j?.city, region: j?.region, country: j?.country };
}

async function updateProfileLocation(api, { city, region, country }) {
  const currentUser = api.getCurrentUser?.();
  if (!currentUser) {
    return;
  }
  // v0.11.2: a profile location stuck on a stale/wrong value (e.g. an old
  // VPN session left "New York" while the user is really in Ontario) used to
  // be permanent because we only wrote when blank. We ALSO self-correct,
  // but ONLY a location WE previously auto-set (tracked via GEO_AUTOSET_KEY) —
  // a value the user typed manually is never overwritten. (v0.15 makes this
  // guard unconditional: the old onlyIfBlank:false call path skipped it and
  // silently clobbered hand-typed locations with IP geo.)
  const existing = (currentUser.location || "").trim();
  const wasAutoSet = (() => { try { return localStorage.getItem(GEO_AUTOSET_KEY) === existing; } catch { return false; } })();
  if (existing && !wasAutoSet) {
    return; // manual / unknown-origin value: leave it alone
  }

  // Only write fully-structured three-part locations — a partial value would
  // fail server-side validation on the user's next manual save.
  const loc = city && region && country ? `${city}, ${region}, ${country}` : "";
  if (!loc || loc === existing) {
    return;
  }

  try {
    await ajax(`/u/${encodeURIComponent(currentUser.username)}.json`, {
      type: "PUT",
      data: { location: loc },
    });
    currentUser.location = loc;
    try { localStorage.setItem(GEO_AUTOSET_KEY, loc); } catch {}
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

async function bootstrapGeo(api, { persistIp }) {
  const { ip, city, region, country } = await resolveGeo();

  const countryName = COUNTRY_NAMES[country] || country;
  const toks = tokenizePieces(city, region, countryName, country).filter(Boolean);
  const csv = toks.length ? toks.join(",") : "toronto,gta,ontario,canada";

  if (tokensChanged(csv)) {
    localStorage.setItem(GEO_TOKENS_KEY, csv);
    dispatchGeoUpdated();
  }
  await updateProfileLocation(api, { city, region, country: countryName });

  // v0.15: persist whichever ip we know. The detect endpoint hands EVERY
  // visitor their (masked) ip — the old path only ever had one via the
  // staff-gated serializer — so the network-change check works for everyone.
  const knownIp = persistIp || ip || "";
  if (knownIp) {
    localStorage.setItem(GEO_LAST_IP_KEY, knownIp);
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
      await bootstrapGeo(api, { persistIp: sessionIp });
      // 2026-06-08: NEVER hard-reload. Behind Cloudflare/HAProxy the per-request
      // client_ip legitimately varies (different edge), so ipChanged was
      // chronically true and window.location.reload() fired on nearly every
      // fresh load (throttled to 60s) = the "double load" users reported. Geo
      // ranking is server-side and picks up new tokens on the next natural
      // fetch; a soft event refreshes any listening widget without a reload.
      if (ipChanged && !firstRun) {
        dispatchGeoUpdated();
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
      IPINFO_TOKEN = (ss.rr_geo_ipinfo_token || "").trim();
      GEO_SOURCE = (ss.rr_geo_source || "auto").toLowerCase().trim();
      await refreshGeoIfNeeded(api);

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
