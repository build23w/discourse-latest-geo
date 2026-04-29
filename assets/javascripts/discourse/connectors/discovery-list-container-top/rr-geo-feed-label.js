// Superseded by rr-geo-feed-label.gjs in v0.3.0. Kept as a stub because the
// workspace doesn't allow file deletion. Discourse may load both -- the .gjs
// component takes precedence.
import Component from "@glimmer/component";
import { service } from "@ember/service";

export default class RrGeoFeedLabelLegacy extends Component {
  @service currentUser;
}
