# frozen_string_literal: true

module RrGeo
  class LocationsController < ::ApplicationController
    requires_plugin 'discourse-latest-geo'
    before_action :ensure_logged_in, only: [:update, :update_interests]
    skip_before_action :preload_json
    skip_before_action :check_xhr

    # PUT /rr-geo/location.json
    # body: { location: "Toronto, Ontario" }
    # Updates the current user's profile location. Empty string clears it.
    def update
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled

      loc = params[:location].to_s.strip
      # Light sanity caps -- Discourse's UserProfile.location is varchar(3000) but
      # nobody types more than ~100 chars in practice; reject anything wild.
      raise Discourse::InvalidParameters, 'location' if loc.length > 200

      profile = current_user.user_profile || current_user.build_user_profile
      profile.location = loc.presence
      profile.save!

      tokens = ::RrGeo::Util.tokens_from_location(loc)

      render json: {
        ok:        true,
        location:  loc,
        tokens:    tokens,
        username:  current_user.username
      }
    end

    # PUT /rr-geo/interests.json
    # body: { tags: ["hvac","rebates"], categories: ["renovations","roofing"] }
    # The client-side online model distills its top-liked tag/category NAMES and
    # syncs them here; the hybrid feed ranker boosts matching topics. Stored on a
    # user custom field as compact JSON.
    def update_interests
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled
      clean = lambda do |arr|
        Array(arr).map { |x| x.to_s.downcase.strip[0, 40] }.reject(&:blank?).uniq.first(25)
      end
      profile = { 'tags' => clean.call(params[:tags]), 'categories' => clean.call(params[:categories]), 'updated_at' => Time.now.to_i }
      current_user.custom_fields['rr_interest_profile'] = profile.to_json
      current_user.save_custom_fields
      render json: { ok: true, tags: profile['tags'], categories: profile['categories'] }
    end

    # GET /rr-geo/suggestions.json?q=tor
    # Returns a list of common matching cities. Built-in list focused on Canada
    # since the forum's primary audience is Canadian renovation. Easy to extend.
    def suggestions
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled

      q = params[:q].to_s.strip.downcase
      pool = COMMON_CITIES
      results =
        if q.length < 2
          pool.first(8)
        else
          pool.select { |c| c.downcase.include?(q) }.first(8)
        end

      render json: { suggestions: results }
    end

    COMMON_CITIES = [
      # GTA + south Ontario (the home turf)
      "Toronto, Ontario", "Mississauga, Ontario", "Brampton, Ontario", "Hamilton, Ontario",
      "Markham, Ontario", "Vaughan, Ontario", "Richmond Hill, Ontario", "Oakville, Ontario",
      "Burlington, Ontario", "Oshawa, Ontario", "Whitby, Ontario", "Pickering, Ontario",
      "Ajax, Ontario", "Newmarket, Ontario", "Aurora, Ontario", "King City, Ontario",
      "Etobicoke, Ontario", "Scarborough, Ontario", "North York, Ontario", "East York, Ontario",
      # Other major Ontario
      "Ottawa, Ontario", "Kitchener, Ontario", "Waterloo, Ontario", "Cambridge, Ontario",
      "London, Ontario", "Windsor, Ontario", "Barrie, Ontario", "Guelph, Ontario",
      "Sudbury, Ontario", "Kingston, Ontario", "Niagara Falls, Ontario",
      # Other provinces
      "Vancouver, BC", "Surrey, BC", "Burnaby, BC", "Richmond, BC", "Victoria, BC",
      "Calgary, Alberta", "Edmonton, Alberta", "Red Deer, Alberta",
      "Montreal, Quebec", "Laval, Quebec", "Quebec City, Quebec", "Gatineau, Quebec",
      "Winnipeg, Manitoba", "Halifax, Nova Scotia", "Saskatoon, Saskatchewan",
      "Regina, Saskatchewan", "St. John's, Newfoundland", "Charlottetown, PEI",
      "Fredericton, New Brunswick", "Whitehorse, Yukon"
    ].freeze
  end
end
