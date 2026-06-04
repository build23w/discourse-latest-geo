import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";

// ============================================================================
// rr-geo-recommender  (v0.5.0)
// A tiny ONLINE LOGISTIC-REGRESSION recommender that runs entirely in the
// browser, side-by-side with the user. No libraries, no server training.
//
// How it works (this is the whole "model"):
//   * Every topic is represented as a sparse set of content features:
//       "cat:<category name>" and "tag:<tag name>".
//   * The model is a weight per feature (w) + a bias (b), kept in localStorage.
//   * Predicted interest = sigmoid(b + sum of w[f] for the topic's features).
//   * On each interaction we take ONE gradient-descent step:
//       open a topic        -> label 1 (positive)
//       upvote a topic      -> label 1, higher learning rate (strong positive)
//       downvote a topic    -> label 0 (negative)
//       shown but ignored   -> label 0, small learning rate (weak negative)
//     update:  err = label - pred;  w[f] += lr * err;  b += lr * err * 0.1
//   * Periodic L2 decay keeps weights from running away.
//
// We DON'T reorder the DOM (that fought Ember + broke mobile). Instead the model
// distills the user's top-liked tags/categories and syncs them to the server
// (PUT /rr-geo/interests.json); the server-side hybrid ranker boosts matches.
// On-device learning + server-side ranking = personalized, private, robust.
// ============================================================================

const MODEL_KEY = "rr_rec_model_v1";
const LR = 0.12;            // base learning rate
const L2 = 0.0015;          // weight decay
const CLIP = 6;             // max |weight|
const SYNC_DEBOUNCE_MS = 4000;
const MAX_SYNC_TERMS = 15;

let pendingImpressions = {}; // topicId -> [features]  (shown this page, not yet clicked)
let syncTimer = null;
let wired = false;

function loadModel() {
  try {
    const raw = localStorage.getItem(MODEL_KEY);
    if (raw) { return JSON.parse(raw); }
  } catch (e) {}
  return { w: {}, b: 0, n: 0 };
}
function saveModel(m) {
  try { localStorage.setItem(MODEL_KEY, JSON.stringify(m)); } catch (e) {}
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
  // occasional L2 decay so the model stays fresh + bounded
  if (m.n % 12 === 0) {
    Object.keys(m.w).forEach((f) => {
      m.w[f] *= (1 - L2);
      if (Math.abs(m.w[f]) < 0.01) { delete m.w[f]; } // prune tiny weights
    });
  }
  saveModel(m);
  scheduleSync();
}

// ---- feature extraction from a topic-list row ----
function clean(s) { return (s || "").toString().trim().toLowerCase(); }

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
  return feats;
}

function rowFromEl(el) {
  return el.closest ? el.closest(".topic-list-item[data-topic-id]") : null;
}

// ---- sync distilled top features to the server ----
function scheduleSync() {
  if (syncTimer) { clearTimeout(syncTimer); }
  syncTimer = setTimeout(syncProfile, SYNC_DEBOUNCE_MS);
}

function syncProfile() {
  const m = loadModel();
  const entries = Object.keys(m.w)
    .map((f) => [f, m.w[f]])
    .filter((e) => e[1] > 0.15)              // only confidently-liked features
    .sort((a, b) => b[1] - a[1]);
  const tags = [];
  const cats = [];
  for (let i = 0; i < entries.length; i++) {
    const f = entries[i][0];
    if (f.indexOf("tag:") === 0 && tags.length < MAX_SYNC_TERMS) { tags.push(f.slice(4)); }
    else if (f.indexOf("cat:") === 0 && cats.length < MAX_SYNC_TERMS) { cats.push(f.slice(4)); }
  }
  if (!tags.length && !cats.length) { return; }
  ajax("/rr-geo/interests.json", { type: "PUT", data: { tags, categories: cats } }).catch(() => {});
}

// shown-but-ignored topics become weak negatives when the user leaves the page
function flushImpressions() {
  const ids = Object.keys(pendingImpressions);
  for (let i = 0; i < ids.length; i++) {
    learn(pendingImpressions[ids[i]], 0, 0.25);
  }
  pendingImpressions = {};
}

function recordImpressions() {
  document.querySelectorAll(".topic-list-item[data-topic-id]").forEach((row) => {
    const id = row.getAttribute("data-topic-id");
    if (id && !pendingImpressions[id]) { pendingImpressions[id] = featuresForRow(row); }
  });
}

function wireInteractions() {
  if (wired) { return; }
  wired = true;
  document.addEventListener("click", (e) => {
    const t = e.target;
    if (!t || !t.closest) { return; }
    // upvote / downvote (vote control lives in the theme; we just observe)
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
    // opening a topic = positive
    const link = t.closest("a.title.raw-topic-link, a.raw-topic-link, .topic-list-item .title a");
    if (link) {
      const row = rowFromEl(link);
      const feats = featuresForRow(row);
      if (feats.length) {
        const id = row && row.getAttribute("data-topic-id");
        if (id) { delete pendingImpressions[id]; }
        learn(feats, 1, 1);
      }
    }
  }, true);
}

function isFeedPath(url) {
  return /^\/($|latest|top|hot|categories|c\/|tag\/|new|unread)/.test(url || "");
}

export default {
  name: "rr-geo-recommender",
  initialize() {
    if (typeof window === "undefined" || !window.localStorage) { return; }
    withPluginApi("0.8.31", (api) => {
      const cu = api.getCurrentUser && api.getCurrentUser();
      if (!cu) { return; } // only personalize for logged-in users
      wireInteractions();
      api.onPageChange((url) => {
        // leaving a feed page: turn un-clicked impressions into weak negatives
        flushImpressions();
        if (isFeedPath(url)) {
          // let the list render, then snapshot what was shown
          setTimeout(recordImpressions, 600);
          setTimeout(recordImpressions, 1600);
        }
      });
    });
  },
};
