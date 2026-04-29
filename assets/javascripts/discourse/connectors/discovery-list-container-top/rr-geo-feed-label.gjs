// IMPORTANT: this file MUST be removed from the repo before the next rebuild.
// Discourse 2026.5's Rollup compiler creates one module export per filename,
// so the .hbs + .gjs pair below produces a duplicate export and the entire
// plugin fails to load with:
//   "Duplicate export 'discourse$connectors$...$rr__geo__feed__label$$__module'"
//
// Run from your repo root before `git push`:
//   git rm assets/javascripts/discourse/connectors/discovery-list-container-top/rr-geo-feed-label.gjs
//   git rm assets/javascripts/discourse/connectors/discovery-list-container-top/rr-geo-feed-label.hbs
//   git rm assets/javascripts/discourse/connectors/discovery-list-container-top/rr-geo-feed-label.js
//
// The active editor lives in rr-geo-feed-label-editor.gjs (different basename,
// different connector module, no collision).
