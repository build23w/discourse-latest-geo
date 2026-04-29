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
  "Toronto, Ontario", "Mississauga, Ontario", "Brampton, Ontario",
  "Hamilton, Ontario", "Ottawa, Ontario", "Vancouver, BC",
  "Calgary, Alberta", "Montreal, Quebec",
];

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

export default class RrGeoFeedLabelEditor extends Component {
  @service currentUser;
  @service router;

  @tracked editing = false;
  @tracked saving = false;
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

  get recentLocations() { return readRecents(); }
  get currentLocation() {
    if (this._locationOverride !== null) return this._locationOverride;
    return this.currentUser?.location || "";
  }

  @action
  startEditing(event) {
    if (event) event.stopPropagation();
    if (!this.currentUser) {
      window.location.href =
        "/login?return_path=" + encodeURIComponent(location.pathname + location.search);
      return;
    }
    this.editing = true;
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
      this.errorMessage = "Couldn't save. Try again?";
      try { popupAjaxError(e); } catch {}
    } finally {
      this.saving = false;
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
      <div class="rr-geo-feed-label is-guest" role="note" aria-live="polite">
        <span class="rr-geo-feed-label__icon">📍</span>
        <a href="/login">Log in</a>
        to set your location and get a feed tuned to your area.
      </div>
    {{else if this.editing}}
      <div class="rr-geo-feed-label is-editing" role="dialog" aria-label="Edit your location">
        <span class="rr-geo-feed-label__icon">📍</span>
        <div class="rr-geo-edit">
          <input class="rr-geo-edit__input"
                 type="text"
                 value={{this.inputValue}}
                 placeholder="e.g. Toronto, Ontario"
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
          {{#if this.currentLocation}}
            <button class="rr-geo-edit__clear" type="button" {{on "click" this.clearLocation}}>
              Clear my location
            </button>
          {{/if}}
        </div>
      </div>
    {{else if this.currentLocation}}
      <button class="rr-geo-feed-label is-set" type="button" {{on "click" this.startEditing}} aria-label="Edit your location">
        <span class="rr-geo-feed-label__icon">📍</span>
        <span class="rr-geo-feed-label__text">Personalized for <strong>{{this.currentLocation}}</strong></span>
        <span class="rr-geo-feed-label__edit-hint">Edit ✎</span>
      </button>
    {{else}}
      <button class="rr-geo-feed-label is-unset" type="button" {{on "click" this.startEditing}}>
        <span class="rr-geo-feed-label__icon">📍</span>
        <span class="rr-geo-feed-label__text">Add your location for a personalized feed</span>
        <span class="rr-geo-feed-label__edit-hint">Set →</span>
      </button>
    {{/unless}}
  </template>
}
