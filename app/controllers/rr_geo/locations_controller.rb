# frozen_string_literal: true

module RrGeo
  class LocationsController < ::ApplicationController
    requires_plugin 'discourse-latest-geo'
    before_action :ensure_logged_in, only: [:update, :update_interests]
    skip_before_action :preload_json
    skip_before_action :check_xhr

    # PUT /rr-geo/location.json
    # body: { location: "Toronto, Ontario, Canada" }
    # Updates the current user's profile location. Empty string clears it.
    def update
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled

      loc = params[:location].to_s.strip
      raise Discourse::InvalidParameters, 'location' if loc.length > 200

      # v0.11: a non-empty location must be structured
      # "City, Province/State, Country" so graded proximity has all levels.
      if loc.present?
        parts = loc.split(',').map(&:strip).reject(&:blank?)
        if parts.length < 3
          return render json: {
            ok: false,
            error: 'Please include your town/city, province/state, and country — e.g. "Orangeville, Ontario, Canada".'
          }, status: 422
        end
        loc = parts.first(3).join(', ')
      end

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
    # body: { tags: ["hvac|0.62","rebates"], categories: ["roofing|0.40"] }
    # v0.10: entries are "name|weight" (weight 0..1, the client model's
    # normalized confidence) — bare names still accepted (weight 1.0).
    # Stored as [[name, w], ...] JSON on a user custom field; the feed ranker
    # boosts matching topics PROPORTIONALLY to weight.
    def update_interests
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled
      clean = lambda do |arr|
        Array(arr).map do |x|
          s = x.to_s.downcase.strip
          name, w = s.split('|', 2)
          name = name.to_s.strip[0, 40]
          next nil if name.blank?
          [name, (w ? w.to_f : 1.0).clamp(0.0, 1.0).round(2)]
        end.compact.uniq { |n, _| n }.first(25)
      end
      profile = {
        'tags'       => clean.call(params[:tags]),
        'categories' => clean.call(params[:categories]),
        'updated_at' => Time.now.to_i
      }
      current_user.custom_fields['rr_interest_profile'] = profile.to_json
      current_user.save_custom_fields
      render json: { ok: true, tags: profile['tags'], categories: profile['categories'] }
    end

    # GET /rr-geo/prior.json?tokens=orangeville,ontario
    # v0.10 cold-start prior: top tags among recent geo-matching topics.
    # Anon-safe (no per-user state, cached 1h per token set) — used to seed
    # brand-new client models so small communities don't start blank.
    def prior
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled

      toks =
        if params[:tokens].present?
          params[:tokens].to_s.downcase.split(',')
            .map { |t| t.gsub(/[^a-z0-9 -]/, '').strip }
            .reject { |t| t.length < 3 }
            .first(8)
        elsif current_user
          ::RrGeo::Util.tokens_from_location(current_user.user_profile&.location)
        end
      if toks.blank?
        toks = SiteSetting.rr_geo_default_tokens.to_s.split(',').map(&:strip).reject(&:blank?)
      end
      raise Discourse::InvalidParameters, 'tokens' if toks.blank?

      key = "rr_geo_prior_v1_#{Digest::MD5.hexdigest(toks.sort.join(','))[0, 12]}"
      tags = ::Discourse.cache.fetch(key, expires_in: 1.hour) do
        conn = ActiveRecord::Base.connection
        pats = ::RrGeo::Util.quote_patterns(toks.map { |t| "%#{ActiveRecord::Base.sanitize_sql_like(t)}%" })
        conn.select_values(
          "SELECT tg.name FROM topic_tags tt JOIN tags tg ON tg.id = tt.tag_id " \
          "WHERE tt.topic_id IN (" \
          "SELECT id FROM topics WHERE deleted_at IS NULL AND visible " \
          "AND bumped_at > (now() - INTERVAL '90 days') " \
          "AND title ILIKE ANY (ARRAY[#{pats}]) LIMIT 300" \
          ") GROUP BY tg.name ORDER BY COUNT(*) DESC LIMIT 12"
        )
      end

      render json: { ok: true, tags: tags }
    end

    # GET /rr-geo/suggestions.json?q=tor
    def suggestions
      raise Discourse::NotFound unless SiteSetting.rr_geo_enabled

      q = params[:q].to_s.strip.downcase
      pool = COMMON_CITIES
      results =
        if q.length < 2
          pool.first(8)
        else
          # v0.14: curated list first (home-market polish), then the full
          # ~19.8K-locality geo mesh so ANY Canada/US town autocompletes.
          curated = pool.select { |c| c.downcase.include?(q) }
          mesh =
            if defined?(::RrGeo::GeoMesh)
              begin
                ::RrGeo::GeoMesh.search(q, limit: 8)
              rescue StandardError
                []
              end
            else
              []
            end
          (curated + mesh).uniq { |c| c.downcase }.first(8)
        end

      render json: { suggestions: results }
    end

    COMMON_CITIES = [
      # GTA + south Ontario (the home turf)
      "Toronto, Ontario, Canada", "Mississauga, Ontario, Canada", "Brampton, Ontario, Canada", "Hamilton, Ontario, Canada",
      "Markham, Ontario, Canada", "Vaughan, Ontario, Canada", "Richmond Hill, Ontario, Canada", "Oakville, Ontario, Canada",
      "Burlington, Ontario, Canada", "Oshawa, Ontario, Canada", "Whitby, Ontario, Canada", "Pickering, Ontario, Canada",
      "Ajax, Ontario, Canada", "Newmarket, Ontario, Canada", "Aurora, Ontario, Canada", "King City, Ontario, Canada",
      "Etobicoke, Ontario, Canada", "Scarborough, Ontario, Canada", "North York, Ontario, Canada", "East York, Ontario, Canada",
      # Other major Ontario
      "Ottawa, Ontario, Canada", "Kitchener, Ontario, Canada", "Waterloo, Ontario, Canada", "Cambridge, Ontario, Canada",
      "London, Ontario, Canada", "Windsor, Ontario, Canada", "Barrie, Ontario, Canada", "Guelph, Ontario, Canada",
      "Sudbury, Ontario, Canada", "Kingston, Ontario, Canada", "Niagara Falls, Ontario, Canada",
      # Other provinces
      "Vancouver, BC, Canada", "Surrey, BC, Canada", "Burnaby, BC, Canada", "Richmond, BC, Canada", "Victoria, BC, Canada",
      "Calgary, Alberta, Canada", "Edmonton, Alberta, Canada", "Red Deer, Alberta, Canada",
      "Montreal, Quebec, Canada", "Laval, Quebec, Canada", "Quebec City, Quebec, Canada", "Gatineau, Quebec, Canada",
      "Winnipeg, Manitoba, Canada", "Halifax, Nova Scotia, Canada", "Saskatoon, Saskatchewan, Canada",
      "Regina, Saskatchewan, Canada", "St. John's, Newfoundland, Canada", "Charlottetown, PEI, Canada",
      "Fredericton, New Brunswick, Canada", "Whitehorse, Yukon, Canada"
    ].freeze
  end
end
