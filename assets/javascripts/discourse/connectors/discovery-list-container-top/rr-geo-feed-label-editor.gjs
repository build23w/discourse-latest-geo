import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";
import { action } from "@ember/object";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

const RECENTS_KEY = "rr-geo.recent-locations";
const RECENTS_MAX = 5;

const FALLBACK_CITIES = [
  "Toronto, Ontario, Canada", "Mississauga, Ontario, Canada", "Brampton, Ontario, Canada",
  "Hamilton, Ontario, Canada", "Ottawa, Ontario, Canada", "Vancouver, BC, Canada",
  "Calgary, Alberta, Canada", "Montreal, Quebec, Canada",
];

// v0.11: locations are structured "City, Province/State, Country" so the
// server can grade proximity (city > nearby > province > country).
const STRUCTURE_ERROR =
  'Please include town/city, province/state, and country — e.g. "Orangeville, Ontario, Canada"';

function isStructured(loc) {
  return loc.split(",").map((p) => p.trim()).filter(Boolean).length >= 3;
}

function readRecents() {
  try {
    const raw = localStorage.getItem(RECENTS_KEY);
    if (!raw) return [];
    const list = JSON.parse(raw);
    return Array.isArray(list) ? list.slice(0, RECENTS_MAX) : [];
  } catch {
    return [];
  }
}
function writeRecents(loc) {
  if (!loc) return;
  let list = readRecents().filter((x) => x !== loc);
  list.unshift(loc);
  list = list.slice(0, RECENTS_MAX);
  try { localStorage.setItem(RECENTS_KEY, JSON.stringify(list)); } catch {}
}

// v0.13: opt-in device-GPS path. The browser's own permission prompt is the
// consent gate; we never store coordinates — they're immediately reverse-
// geocoded (BigDataCloud's free client endpoint, no key) down to the same
// "City, Province/State, Country" string the manual path saves. IP
// auto-detection (v0.15: Cloudflare edge first, ipinfo fallback) is unchanged
// and remains the zero-friction default.
//
// v0.14.1: the GPS button is promoted INTO the collapsed bar — one click
// from the feed, no need to open the editor first. The bar itself is a
// redesigned engagement surface (rr-geo-bar) fully styled by this plugin.
const REVERSE_GEOCODE_URL =
  "https://api.bigdatacloud.net/data/reverse-geocode-client";

export default class RrGeoFeedLabelEditor extends Component {
  @service currentUser;
  @service router;
  @service siteSettings;

  @tracked editing = false;
  @tracked saving = false;
  @tracked locating = false;
  @tracked justSaved = false;
  @tracked inputValue = "";
  @tracked suggestions = [];
  @tracked errorMessage = null;
  // _locationOverride is null when we're rendering whatever the currentUser
  // service has, and a string after the user saves a new value. Because it's
  // @tracked, setting it triggers an immediate re-render of the label without
  // waiting for a route refresh or page reload. currentUser.location itself
  // isn't @tracked on the service, so mutating it directly doesn't fire
  // reactivity -- this override is the canonical source the template reads.
  @tracked _locationOverride = null;

  _flashTimer = null;

  get recentLocations() { return readRecents(); }
  get currentLocation() {
    if (this._locationOverride !== null) return this._locationOverride;
    return this.currentUser?.location || "";
  }

  get gpsAvailable() {
    return (
      typeof navigator !== "undefined" &&
      !!navigator.geolocation &&
      this.siteSettings?.rr_geo_gps_button_enabled !== false
    );
  }

  // Short display form for the collapsed bar: "Orangeville, Ontario" (the
  // country is implied and eats space on mobile).
  get shortLocation() {
    const parts = this.currentLocation.split(",").map((p) => p.trim()).filter(Boolean);
    return parts.slice(0, 2).join(", ");
  }

  _flashSaved() {
    this.justSaved = true;
    if (this._flashTimer) clearTimeout(this._flashTimer);
    this._flashTimer = setTimeout(() => { this.justSaved = false; }, 3500);
  }

  _requireLogin() {
    if (this.currentUser) return false;
    window.location.href =
      "/login?return_path=" + encodeURIComponent(location.pathname + location.search);
    return true;
  }

  @action
  startEditing(event) {
    if (event) event.stopPropagation();
    if (this._requireLogin()) return;
    this.editing = true;
    this.justSaved = false;
    this.inputValue = this.currentLocation;
    this.errorMessage = null;
    this.suggestions = [];
    setTimeout(() => {
      const inp = document.querySelector(".rr-geo-edit__input");
      if (inp) { inp.focus(); inp.select(); }
    }, 30);
  }

  @action
  cancelEditing(event) {
    if (event) event.stopPropagation();
    this.editing = false;
    this.suggestions = [];
    this.errorMessage = null;
  }

  @action
  inputChanged(event) {
    const v = event.target.value;
    this.inputValue = v;
    this.errorMessage = null;
    if (v.length < 2) { this.suggestions = []; return; }
    const lower = v.toLowerCase();
    this.suggestions = FALLBACK_CITIES.filter((c) => c.toLowerCase().includes(lower)).slice(0, 6);
    ajax("/rr-geo/suggestions.json", { data: { q: v } })
      .then((d) => {
        const fresh = (d && d.suggestions) || [];
        if (fresh.length) this.suggestions = fresh.slice(0, 6);
      })
      .catch(() => {});
  }

  @action
  pickSuggestion(loc, event) {
    if (event) event.stopPropagation();
    this.inputValue = loc;
    this.suggestions = [];
    this.save();
  }

  @action
  pickRecent(loc, event) {
    if (event) event.stopPropagation();
    this.inputValue = loc;
    this.save();
  }

  @action
  async save(event) {
    if (event) event.stopPropagation();
    if (this.saving) return;
    const newLoc = (this.inputValue || "").trim();
    if (newLoc && !isStructured(newLoc)) {
      this.errorMessage = STRUCTURE_ERROR;
      return;
    }
    this.saving = true;
    this.errorMessage = null;
    try {
      await ajax("/rr-geo/location.json", {
        type: "PUT",
        data: { location: newLoc },
      });
      // === IMMEDIATE LABEL REFRESH ===
      // 1. Set the @tracked override -- this re-renders the label THIS FRAME
      //    so the user sees the new location instantly with no flicker.
      this._locationOverride = newLoc;
      // 2. Best-effort: also mutate currentUser.location so other parts of
      //    Discourse (search filters, profile pages, etc.) see the new value.
      //    Wrapped in try/catch because the service property may be frozen on
      //    some Discourse versions; the override above is what guarantees the
      //    label updates regardless.
      if (this.currentUser) {
        try { this.currentUser.location = newLoc; } catch (_) { /* ignore */ }
      }
      writeRecents(newLoc);
      this.editing = false;
      this.suggestions = [];
      if (newLoc) this._flashSaved();

      // Notify the geo initializer so it re-tokenizes localStorage tokens
      // (used by feed prioritization on the next route load).
      try { window.dispatchEvent(new CustomEvent("rr-geo-updated", { detail: { location: newLoc } })); } catch {}

      // Soft route refresh in the background -- doesn't block the label re-render.
      // The feed re-fetches with the new location tokens; if it fails for any
      // reason, the label is already correct and the next navigation will pick up
      // the new prioritization naturally.
      try {
        if (this.router && typeof this.router.refresh === "function") {
          this.router.refresh();
        }
      } catch (_) { /* silent -- label is already updated */ }
    } catch (e) {
      const serverMsg = e?.jqXHR?.responseJSON?.error;
      this.errorMessage = serverMsg || "Couldn't save. Try again?";
      if (!serverMsg) { try { popupAjaxError(e); } catch {} }
    } finally {
      this.saving = false;
    }
  }

  // v0.14.1: callable from the COLLAPSED bar (one click) or from the editor.
  // Collapsed-bar errors open the editor with the message so the user can
  // fall back to typing without hunting for the input.
  @action
  async useDeviceLocation(event) {
    if (event) event.stopPropagation();
    if (this.locating) return;
    if (this._requireLogin()) return;
    if (!this.gpsAvailable) {
      this._gpsError("Your browser doesn't support device location — type your city instead.");
      return;
    }
    this.locating = true;
    this.errorMessage = null;
    try {
      const pos = await new Promise((resolve, reject) =>
        navigator.geolocation.getCurrentPosition(resolve, reject, {
          enableHighAccuracy: false,
          timeout: 10000,
          maximumAge: 300000,
        })
      );
      const { latitude, longitude } = pos.coords;
      const res = await fetch(
        `${REVERSE_GEOCODE_URL}?latitude=${encodeURIComponent(latitude)}&longitude=${encodeURIComponent(longitude)}&localityLanguage=en`
      );
      if (!res.ok) throw new Error(`reverse-geocode ${res.status}`);
      const j = await res.json();
      const city = (j.city || j.locality || "").trim();
      const region = (j.principalSubdivision || "").trim();
      const country = (j.countryName || "").trim();
      if (!city || !region || !country) {
        this._gpsError("Couldn't resolve a town/city from your device location — try typing it instead.");
        return;
      }
      this.inputValue = `${city}, ${region}, ${country}`;
      this.suggestions = [];
      await this.save(null);
    } catch (e) {
      this._gpsError(
        e && e.code === 1
          ? "Location permission was declined — no problem, you can type your city instead."
          : "Couldn't get your device location — try typing your city instead."
      );
    } finally {
      this.locating = false;
    }
  }

  _gpsError(msg) {
    this.errorMessage = msg;
    if (!this.editing) {
      // surface the fallback path immediately
      this.editing = true;
      this.inputValue = this.currentLocation;
      this.suggestions = [];
      setTimeout(() => {
        const inp = document.querySelector(".rr-geo-edit__input");
        if (inp) inp.focus();
      }, 30);
    }
  }

  @action
  async clearLocation(event) {
    if (event) event.stopPropagation();
    this.inputValue = "";
    await this.save(null);
  }

  <template>
    {{#unless this.currentUser}}
      <div class="rr-geo-bar is-guest" role="note" aria-live="polite">
        <span class="rr-geo-bar__pin" aria-hidden="true">📍</span>
        <span class="rr-geo-bar__text">
          <a href="/login">Log in</a> to get a feed built for <strong>your area</strong>
        </span>
      </div>
    {{else if this.editing}}
      <div class="rr-geo-bar is-editing" role="dialog" aria-label="Edit your location">
        <div class="rr-geo-edit">
          <div class="rr-geo-edit__head">
            <span class="rr-geo-bar__pin" aria-hidden="true">📍</span>
            <span class="rr-geo-edit__title">Where should your local feed point?</span>
          </div>

          {{#if this.gpsAvailable}}
            <button class="rr-geo-edit__gps-btn"
                    type="button"
                    disabled={{this.locating}}
                    {{on "click" this.useDeviceLocation}}>
              {{if this.locating "Locating…" "📡 Use my device location"}}
            </button>
            <div class="rr-geo-edit__divider"><span>or type it</span></div>
          {{/if}}

          <div class="rr-geo-edit__row">
            <input class="rr-geo-edit__input"
                   type="text"
                   value={{this.inputValue}}
                   placeholder="e.g. Toronto, Ontario, Canada"
                   maxlength="200"
                   {{on "input" this.inputChanged}} />
            <button class="rr-geo-edit__save"
                    type="button"
                    disabled={{this.saving}}
                    {{on "click" this.save}}>
              {{if this.saving "Saving..." "Save"}}
            </button>
            <button class="rr-geo-edit__cancel"
                    type="button"
                    {{on "click" this.cancelEditing}}>
              Cancel
            </button>
          </div>

          {{#if this.suggestions.length}}
            <ul class="rr-geo-edit__suggestions" role="listbox">
              {{#each this.suggestions as |s|}}
                <li>
                  <button class="rr-geo-edit__suggestion" type="button" {{on "click" (fn this.pickSuggestion s)}}>
                    📍 {{s}}
                  </button>
                </li>
              {{/each}}
            </ul>
          {{/if}}

          {{#if this.recentLocations.length}}
            <div class="rr-geo-edit__recents">
              <span class="rr-geo-edit__recents-label">Recent:</span>
              {{#each this.recentLocations as |r|}}
                <button class="rr-geo-edit__recent-chip" type="button" {{on "click" (fn this.pickRecent r)}}>
                  {{r}}
                </button>
              {{/each}}
            </div>
          {{/if}}

          {{#if this.errorMessage}}
            <div class="rr-geo-edit__error" role="alert">{{this.errorMessage}}</div>
          {{/if}}

          <div class="rr-geo-edit__footer">
            <span class="rr-geo-edit__privacy">Only "City, Province, Country" is saved — never coordinates.</span>
            {{#if this.currentLocation}}
              <button class="rr-geo-edit__clear" type="button" {{on "click" this.clearLocation}}>
                Clear my location
              </button>
            {{/if}}
          </div>
        </div>
      </div>
    {{else}}
      <div class="rr-geo-bar {{if this.currentLocation 'is-set' 'is-unset'}}" aria-live="polite">
        <span class="rr-geo-bar__pin {{unless this.currentLocation 'is-pulsing'}}" aria-hidden="true">📍</span>

        {{#if this.justSaved}}
          <span class="rr-geo-bar__text is-flash">
            ✓ Feed tuned for <strong>{{this.shortLocation}}</strong> — local posts incoming
          </span>
        {{else if this.currentLocation}}
          <button class="rr-geo-bar__text is-link" type="button" {{on "click" this.startEditing}}>
            Local feed: <strong>{{this.shortLocation}}</strong>
          </button>
        {{else}}
          <span class="rr-geo-bar__text">
            Renos, pros &amp; advice from <strong>your area</strong> — set your location
          </span>
        {{/if}}

        <span class="rr-geo-bar__actions">
          {{#if this.gpsAvailable}}
            <button class="rr-geo-bar__gps"
                    type="button"
                    disabled={{this.locating}}
                    title="Use my device location"
                    {{on "click" this.useDeviceLocation}}>
              {{if this.locating "Locating…" (if this.currentLocation "📡 Update" "📡 Use my location")}}
            </button>
          {{/if}}
          <button class="rr-geo-bar__edit" type="button" {{on "click" this.startEditing}}>
            {{if this.currentLocation "Edit ✎" "Type it"}}
          </button>
        </span>
      </div>
    {{/unless}}
  </template>
}
