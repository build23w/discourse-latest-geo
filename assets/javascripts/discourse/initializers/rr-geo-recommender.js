import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";

// ============================================================================
// rr-geo-recommender  (v0.7.0 — adds window.rrRec, the public client hub:
// score()/learn()/geoTokens()/events() so every surface — shorts rail, FAB
// hub, theme widgets — ranks with this ONE model instead of private copies.)
// A tiny ONLINE LOGISTIC-REGRESSION recommender that runs entirely in the
// browser, side-by-side with the user. No libraries, no server training.
//
// The model: every topic is a sparse feature set; the model is a weight per
// feature + bias in localStorage; predicted interest = sigmoid(b + sum w[f]);
// each interaction takes one SGD step; L2 decay + clipping keep it bounded.
//
// v0.6.0 — full-signal upgrade:
//   * IMPRESSIONS FIXED: only rows actually seen (IntersectionObserver,
//     >=50% visible for >=1s) become weak negatives — below-the-fold rows no
//     longer poison the model. Capped per page-view and per session.
//   * DWELL-GRADED OPENS: an open is no longer an unconditional positive.
//     Bounce (<10s) = negative; normal read = positive; deep read (>45s) =
//     strong positive.
//   * FULL EVENT STREAM: core likes, bookmarks, $RENO tips, and replies now
//     teach the model (tips are the strongest signal on the platform).
//   * RICHER FEATURES: author:<username>, geo:local (title overlaps the
//     user's geo tokens), rec:today/rec:week recency buckets, media:img —
//     still a linear model, still microseconds per update.
//   * WEIGHTED SYNC: profile sync sends normalized weights ("name|0.62"),
//     deduped by content hash, min 60s apart — ~90% fewer writes.
//   * CLIENT RE-RANK: registerModelTransformer("topicList") re-orders the
//     DATA (never the DOM) with the full model — bounded lift, guarded for
//     small lists and cold models.
//   * ANON MODE: logged-out visitors learn + re-rank locally; nothing is
//     ever synced. Personalization for traffic spikes at zero server cost.
//   * COLD-START PRIOR: a fresh model seeds itself once from
//     /rr-geo/prior.json (top tags for the visitor's area).
// ============================================================================

const MODEL_KEY = "rr_rec_model_v2";
const LEGACY_MODEL_KEY = "rr_rec_model_v1";
const SYNC_META_KEY = "rr_rec_sync_meta_v1";
const PRIOR_AT_KEY = "rr_rec_prior_at_v1";
const GEO_TOKENS_KEY = "geo.tokens";

const LR = 0.12;             // base learning rate
const L2 = 0.0015;           // weight decay
const CLIP = 6;              // max |weight|
const SYNC_DEBOUNCE_MS = 4000;
const SYNC_MIN_INTERVAL_MS = 60000;
const MAX_SYNC_TERMS = 15;
const EPSILON = 0.25;        // exploration: chance to surface low-confidence features
const SAVE_THROTTLE_MS = 400;

const IMPRESSION_VIEW_MS = 1000;     // must be >=50% visible this long
const IMPRESSION_PAGE_CAP = 40;
const IMPRESSION_SESSION_CAP = 150;

const DWELL_BOUNCE_MS = 10000;
const DWELL_DEEP_MS = 45000;

const RERANK_MAX_LIFT = 8;     // max positions a topic can climb
const RERANK_MIN_TOPICS = 10;  // small-catalog guard
const RERANK_MIN_EVENTS = 20;  // cold-model guard

let pendingImpressions = {};   // topicId -> features (seen, not yet clicked)
let pageImpressions = 0;
let sessionImpressions = 0;
let ioTimers = {};
let observer = null;
let openDwell = null;          // { feats, ts, topicId } — feed click awaiting dwell grade
let syncTimer = null;
let wired = false;
let canSync = false;
let pluginApi = null;

// ---- model persistence (throttled — one localStorage write per burst) ----
let _model = null;
let _dirty = false;
let _saveTimer = null;

function loadModel() {
  if (_model) { return _model; }
  try {
    const raw = localStorage.getItem(MODEL_KEY) || localStorage.getItem(LEGACY_MODEL_KEY);
    if (raw) { _model = JSON.parse(raw); }
  } catch (e) {}
  if (!_model || typeof _model !== "object") { _model = { w: {}, b: 0, n: 0 }; }
  if (!_model.w) { _model.w = {}; }
  return _model;
}

function persistNow() {
  if (!_dirty || !_model) { return; }
  try { localStorage.setItem(MODEL_KEY, JSON.stringify(_model)); } catch (e) {}
  _dirty = false;
}

function saveModel(m) {
  _model = m;
  _dirty = true;
  if (_saveTimer) { return; }
  _saveTimer = setTimeout(() => { _saveTimer = null; persistNow(); }, SAVE_THROTTLE_MS);
}

function sigmoid(z) { return 1 / (1 + Math.exp(-z)); }

function score(model, feats) {
  let z = model.b || 0;
  for (let i = 0; i < feats.length; i++) {
    const w = model.w[feats[i]];
    if (w) { z += w; }
  }
  return sigmoid(z);
}

function learn(feats, label, lrMult) {
  if (!feats || !feats.length) { return; }
  const m = loadModel();
  const lr = LR * (lrMult || 1);
  const pred = score(m, feats);
  const err = label - pred;
  for (let i = 0; i < feats.length; i++) {
    const f = feats[i];
    let w = (m.w[f] || 0) + lr * err;
    if (w > CLIP) { w = CLIP; } else if (w < -CLIP) { w = -CLIP; }
    m.w[f] = w;
  }
  m.b = (m.b || 0) + lr * err * 0.1;
  m.n = (m.n || 0) + 1;
  if (m.n % 12 === 0) {
    Object.keys(m.w).forEach((f) => {
      m.w[f] *= (1 - L2);
      if (Math.abs(m.w[f]) < 0.01) { delete m.w[f]; }
    });
  }
  saveModel(m);
  scheduleSync();
}

// ---- feature extraction ----
function clean(s) { return (s || "").toString().trim().toLowerCase(); }

function geoTokens() {
  try {
    return (localStorage.getItem(GEO_TOKENS_KEY) || "")
      .split(",").map(clean).filter((t) => t.length >= 3);
  } catch (e) { return []; }
}

function titleIsLocal(title) {
  const t = clean(title);
  if (!t) { return false; }
  const toks = geoTokens();
  for (let i = 0; i < toks.length; i++) {
    if (t.indexOf(toks[i]) !== -1) { return true; }
  }
  return false;
}

function featuresForRow(row) {
  if (!row) { return []; }
  const feats = [];
  const catEl = row.querySelector(".badge-category__name, .badge-category .badge-category__name");
  const cat = clean(catEl && catEl.textContent);
  if (cat) { feats.push("cat:" + cat); }
  row.querySelectorAll(".discourse-tag").forEach((t) => {
    const tag = clean(t.textContent);
    if (tag) { feats.push("tag:" + tag); }
  });
  // author (first poster card)
  const posterEl = row.querySelector(".posters a[data-user-card]");
  const author = clean(posterEl && posterEl.dataset.userCard);
  if (author) { feats.push("author:" + author); }
  // geo overlap on title
  const titleEl = row.querySelector(".title.raw-topic-link, a.raw-topic-link, .main-link .title");
  if (titleEl && titleIsLocal(titleEl.textContent)) { feats.push("geo:local"); }
  // recency bucket
  const dateEl = row.querySelector(".activity .relative-date, .relative-date");
  const ms = dateEl && parseInt(dateEl.dataset.time, 10);
  if (ms) {
    const age = Date.now() - ms;
    if (age < 86400000) { feats.push("rec:today"); }
    else if (age < 604800000) { feats.push("rec:week"); }
  }
  // media tile (feed-images theme)
  if (row.querySelector('img[class*="lf-fi"], .topic-image, .lf-fi-thumb img')) {
    feats.push("media:img");
  }
  return feats;
}

// features for the topic the user is currently INSIDE (likes/tips/bookmarks/replies)
function featuresForTopicPage() {
  try {
    const topic = pluginApi?.container?.lookup("controller:topic")?.model;
    if (!topic) { return []; }
    const feats = [];
    const cat = clean(topic.category && topic.category.name);
    if (cat) { feats.push("cat:" + cat); }
    (topic.tags || []).forEach((t) => {
      const tag = clean(t);
      if (tag) { feats.push("tag:" + tag); }
    });
    const author = clean(topic.details?.created_by?.username);
    if (author) { feats.push("author:" + author); }
    if (titleIsLocal(topic.title)) { feats.push("geo:local"); }
    return feats;
  } catch (e) { return []; }
}

function rowFromEl(el) {
  return el.closest ? el.closest(".topic-list-item[data-topic-id]") : null;
}

// ---- sync distilled top features to the server (weighted, deduped) ----
function scheduleSync() {
  if (!canSync) { return; }
  if (syncTimer) { clearTimeout(syncTimer); }
  syncTimer = setTimeout(syncProfile, SYNC_DEBOUNCE_MS);
}

function normW(w) { return Math.min(1, Math.max(0, w / 3)); }

function syncProfile() {
  if (!canSync) { return; }
  const m = loadModel();
  const entries = Object.keys(m.w)
    .map((f) => [f, m.w[f]])
    .filter((e) => e[1] > 0.15)              // only confidently-liked features
    .sort((a, b) => b[1] - a[1]);
  const tags = [];
  const cats = [];
  for (let i = 0; i < entries.length; i++) {
    const f = entries[i][0];
    const w = normW(entries[i][1]).toFixed(2);
    if (f.indexOf("tag:") === 0 && tags.length < MAX_SYNC_TERMS) { tags.push(f.slice(4) + "|" + w); }
    else if (f.indexOf("cat:") === 0 && cats.length < MAX_SYNC_TERMS) { cats.push(f.slice(4) + "|" + w); }
  }
  // ---- EXPLORATION (epsilon-greedy curiosity) ----
  // Sometimes also surface 1-2 features the model has SEEN but is UNSURE
  // about, so the feed shows more of them and the model gets data to decide.
  if (Math.random() < EPSILON) {
    const curious = Object.keys(m.w)
      .map((f) => [f, m.w[f]])
      .filter((e) => e[1] > 0.02 && e[1] < 0.18)
      .sort(() => Math.random() - 0.5)
      .slice(0, 2);
    for (let i = 0; i < curious.length; i++) {
      const f = curious[i][0];
      const w = normW(curious[i][1]).toFixed(2);
      if (f.indexOf("tag:") === 0 && tags.length < MAX_SYNC_TERMS + 2) { tags.push(f.slice(4) + "|" + w); }
      else if (f.indexOf("cat:") === 0 && cats.length < MAX_SYNC_TERMS + 2) { cats.push(f.slice(4) + "|" + w); }
    }
  }

  if (!tags.length && !cats.length) { return; }

  // dedupe + rate-limit: skip when nothing changed or last write was <60s ago
  let meta = {};
  try { meta = JSON.parse(localStorage.getItem(SYNC_META_KEY) || "{}"); } catch (e) {}
  const payloadHash = JSON.stringify([tags, cats]);
  const now = Date.now();
  if (meta.hash === payloadHash) { return; }
  if (meta.at && now - meta.at < SYNC_MIN_INTERVAL_MS) {
    if (syncTimer) { clearTimeout(syncTimer); }
    syncTimer = setTimeout(syncProfile, meta.at + SYNC_MIN_INTERVAL_MS - now + 50);
    return;
  }
  try { localStorage.setItem(SYNC_META_KEY, JSON.stringify({ hash: payloadHash, at: now })); } catch (e) {}
  ajax("/rr-geo/interests.json", { type: "PUT", data: { tags, categories: cats } }).catch(() => {});
}

// ---- cold-start prior: seed a fresh model from the server's geo prior ----
function seedPrior() {
  const m = loadModel();
  if ((m.n || 0) > 0 || Object.keys(m.w).length > 0) { return; }
  let last = 0;
  try { last = parseInt(localStorage.getItem(PRIOR_AT_KEY) || "0", 10); } catch (e) {}
  if (last && Date.now() - last < 86400000) { return; }
  try { localStorage.setItem(PRIOR_AT_KEY, String(Date.now())); } catch (e) {}
  const toks = geoTokens();
  ajax("/rr-geo/prior.json", { data: toks.length ? { tokens: toks.join(",") } : {} })
    .then((r) => {
      const tags = (r && r.tags) || [];
      if (!tags.length) { return; }
      const model = loadModel();
      if ((model.n || 0) > 0) { return; }
      tags.forEach((t) => {
        const tag = clean(t);
        if (tag) { model.w["tag:" + tag] = 0.3; }
      });
      saveModel(model);
    })
    .catch(() => {});
}

// ---- impressions: viewport-gated weak negatives ----
function recordImpression(row) {
  const id = row.getAttribute("data-topic-id");
  if (!id || pendingImpressions[id]) { return; }
  if (pageImpressions >= IMPRESSION_PAGE_CAP) { return; }
  if (sessionImpressions >= IMPRESSION_SESSION_CAP) { return; }
  const feats = featuresForRow(row);
  if (!feats.length) { return; }
  pendingImpressions[id] = feats;
  pageImpressions++;
  sessionImpressions++;
}

function ensureObserver() {
  if (observer || typeof IntersectionObserver === "undefined") { return; }
  observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      const row = entry.target;
      const id = row.getAttribute("data-topic-id");
      if (!id) { return; }
      if (entry.isIntersecting && entry.intersectionRatio >= 0.5) {
        if (!ioTimers[id]) {
          ioTimers[id] = setTimeout(() => {
            delete ioTimers[id];
            recordImpression(row);
          }, IMPRESSION_VIEW_MS);
        }
      } else if (ioTimers[id]) {
        clearTimeout(ioTimers[id]);
        delete ioTimers[id];
      }
    });
  }, { threshold: [0.5] });
}

function observeRows() {
  ensureObserver();
  if (!observer) { return; }
  document.querySelectorAll(".topic-list-item[data-topic-id]").forEach((row) => {
    observer.observe(row);
  });
}

function resetObserver() {
  Object.keys(ioTimers).forEach((id) => clearTimeout(ioTimers[id]));
  ioTimers = {};
  if (observer) { observer.disconnect(); }
  pageImpressions = 0;
}

// shown-but-actually-seen topics become weak negatives when the user moves on
function flushImpressions() {
  const ids = Object.keys(pendingImpressions);
  for (let i = 0; i < ids.length; i++) {
    learn(pendingImpressions[ids[i]], 0, 0.25);
  }
  pendingImpressions = {};
}

// ---- dwell-graded open labels ----
function finalizeDwell(nextUrl) {
  if (!openDwell) { return; }
  if (nextUrl) {
    const m = nextUrl.match(/\/t\/[^/]+\/(\d+)/);
    if (m && m[1] === String(openDwell.topicId)) { return; } // still inside the topic
  }
  const dwell = Date.now() - openDwell.ts;
  const feats = openDwell.feats;
  openDwell = null;
  if (dwell < DWELL_BOUNCE_MS) { learn(feats, 0, 0.8); }        // bounce = negative
  else if (dwell < DWELL_DEEP_MS) { learn(feats, 1, 0.6); }     // skim = mild positive
  else { learn(feats, 1, 1.4); }                                 // deep read = strong positive
}

function wireInteractions() {
  if (wired) { return; }
  wired = true;
  document.addEventListener("click", (e) => {
    const t = e.target;
    if (!t || !t.closest) { return; }

    // feed vote arrows (theme-rendered; we just observe)
    const up = t.closest(".lf-vote__up");
    const down = t.closest(".lf-vote__down");
    if (up || down) {
      const row = rowFromEl(up || down);
      const feats = featuresForRow(row);
      if (feats.length) {
        const id = row && row.getAttribute("data-topic-id");
        if (id) { delete pendingImpressions[id]; }
        learn(feats, up ? 1 : 0, up ? 1.6 : 1.2);
      }
      return;
    }

    // opening a topic from a list = pending dwell grade (not auto-positive)
    const link = t.closest("a.title.raw-topic-link, a.raw-topic-link, .topic-list-item .title a");
    if (link) {
      const row = rowFromEl(link);
      const feats = featuresForRow(row);
      if (feats.length) {
        const id = row && row.getAttribute("data-topic-id");
        if (id) { delete pendingImpressions[id]; }
        finalizeDwell(null); // close out any previous pending open
        openDwell = { feats, ts: Date.now(), topicId: id };
      }
      return;
    }

    // in-topic positives: like / bookmark / $RENO tip / reply submit
    const onTopic = window.location.pathname.indexOf("/t/") === 0;
    if (!onTopic) { return; }
    let label = null;
    let mult = 1;
    if (t.closest(".like-button, .toggle-like, .post-action-menu__like, button.like")) {
      label = 1; mult = 1.5;
    } else if (t.closest(".bookmark, .post-action-menu__bookmark, .bookmark-menu-trigger")) {
      label = 1; mult = 1.5;
    } else if (t.closest('[class*="lf-tip"]')) {
      label = 1; mult = 2.0;   // a tip is the strongest signal on the platform
    } else if (t.closest(".save-or-cancel .create, .composer-actions + .create")) {
      label = 1; mult = 1.6;   // composed a reply
    }
    if (label !== null) {
      const feats = featuresForTopicPage();
      if (feats.length) { learn(feats, label, mult); }
    }
  }, true);
}

// ---- client-side re-rank: reorder DATA before render, never the DOM ----
function featuresForTopicModel(t, categoriesById) {
  const feats = [];
  try {
    const cat = categoriesById && categoriesById[t.category_id];
    if (cat) { feats.push("cat:" + clean(cat.name)); }
    (t.tags || []).forEach((tag) => {
      const tg = clean(tag);
      if (tg) { feats.push("tag:" + tg); }
    });
    if (titleIsLocal(t.title || t.fancy_title)) { feats.push("geo:local"); }
  } catch (e) {}
  return feats;
}

function rerankTopics(topics) {
  if (!Array.isArray(topics) || topics.length < RERANK_MIN_TOPICS) { return; }
  const m = loadModel();
  if ((m.n || 0) < RERANK_MIN_EVENTS) { return; }

  let categoriesById = null;
  try {
    const site = pluginApi?.container?.lookup("service:site") ||
                 pluginApi?.container?.lookup("site:main");
    if (site && site.categories) {
      categoriesById = {};
      site.categories.forEach((c) => { categoriesById[c.id] = c; });
    }
  } catch (e) {}

  const ranked = topics
    .map((t, i) => ({ t, key: i - RERANK_MAX_LIFT * score(m, featuresForTopicModel(t, categoriesById)) }))
    .sort((a, b) => a.key - b.key)
    .map((x) => x.t);
  topics.splice(0, topics.length, ...ranked);
}

function isFeedPath(url) {
  return /^\/($|latest|top|hot|categories|c\/|tag\/|new|unread)/.test(url || "");
}

export default {
  name: "rr-geo-recommender",
  initialize() {
    if (typeof window === "undefined" || !window.localStorage) { return; }
    withPluginApi("0.8.31", (api) => {
      pluginApi = api;
      const ss = api.container.lookup("service:site-settings");
      if (ss && ss.rr_geo_enabled === false) { return; }
      const cu = api.getCurrentUser && api.getCurrentUser();
      const anonOk = !ss || ss.rr_geo_anon_personalization !== false;
      if (!cu && !anonOk) { return; }   // anon mode: learn + re-rank locally, never sync
      canSync = !!cu;
      window.__rrRecActive = true;  // theme learn-bridges defer to this model

      // ---- v0.7.0 PUBLIC CLIENT HUB ----------------------------------
      // One user model, many surfaces. Theme widgets (shorts rail, FAB hub,
      // related-topics, trending ticker) should score and teach through THIS
      // instead of keeping private metric systems. Features use the same
      // vocabulary the model already learns: "tag:x", "cat:x", "author:x",
      // "skill:x", "geo:local", "rec:today", "media:img".
      window.rrRec = {
        version: 7,
        active: true,
        // sigmoid score 0..1 for a sparse feature list
        score(feats) {
          try { return score(loadModel(), feats || []); } catch (e) { return 0.5; }
        },
        // one SGD step: label 1 = liked it, 0 = didn't; mult scales the step
        learn(feats, label, mult) {
          try { learn(feats || [], label ? 1 : 0, mult || 1); } catch (e) {}
        },
        // current geo tokens (same source the server ranks with)
        geoTokens() { return geoTokens(); },
        // how trained the model is (event count) — callers can gate on this
        events() { try { return loadModel().n || 0; } catch (e) { return 0; } },
      };

      wireInteractions();
      seedPrior();

      // re-rank the topic-list DATA with the full local model (guarded; the
      // API may not exist on older cores — degrade silently)
      if ((!ss || ss.rr_geo_client_rerank !== false) &&
          typeof api.registerModelTransformer === "function") {
        try {
          api.registerModelTransformer("topicList", (arg) => {
            try {
              const list = Array.isArray(arg) ? arg : (arg && arg.topics);
              if (list) { rerankTopics(list); }
            } catch (e) {}
          });
        } catch (e) {}
      }

      // ---- shorts engagement: the rail (theme) dispatches
      // CustomEvent("rr-shorts-engage", { detail: { tags: [...],
      // area: "tiling", action: "watch|complete|like|dislike|share" } })
      // so shorts teach the same model that ranks the topic feed. Watching a
      // tiling short makes tiling THREADS surface — video and forum learning
      // reinforce each other.
      window.addEventListener("rr-shorts-engage", (e) => {
        try {
          const d = (e && e.detail) || {};
          const feats = [];
          (d.tags || []).forEach((t) => {
            const c = clean(t);
            if (c) { feats.push("tag:" + c); }
          });
          if (d.area) { feats.push("skill:" + clean(d.area)); }
          if (!feats.length) { return; }
          const action = d.action || "watch";
          const label = action === "dislike" ? 0 : 1;
          const mult = { like: 1.6, complete: 1.5, share: 1.8, dislike: 1.2, watch: 0.8 }[action] || 0.8;
          learn(feats, label, mult);
        } catch (err) {}
      });

      api.onPageChange((url) => {
        finalizeDwell(url);          // grade the open we navigated away from
        flushImpressions();          // seen-but-ignored rows -> weak negatives
        resetObserver();
        if (isFeedPath(url)) {
          setTimeout(observeRows, 600);
          setTimeout(observeRows, 1600);
        }
      });

      window.addEventListener("pagehide", () => {
        finalizeDwell(null);
        flushImpressions();
        persistNow();
      });
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "hidden") { persistNow(); }
      });
    });
  },
};
