# frozen_string_literal: true
# name: discourse-latest-geo
# about: Hybrid relevance feed (location + content-affinity recommender + engagement/votes + freshness) with a click-to-edit location widget. Auto-detects location via ipinfo.io; v0.4.0 adds the weighted multi-signal ranking on top of the original geo prioritization.
# version: 0.6.0
# authors: build23w

enabled_site_setting :rr_geo_enabled

register_asset "stylesheets/common/rr-geo-feed-label.scss"

after_initialize do
  load File.expand_path('../app/controllers/rr_geo/locations_controller.rb', __FILE__)

  Discourse::Application.routes.append do
    put '/rr-geo/location.json'        => 'rr_geo/locations#update'
    get '/rr-geo/suggestions.json'     => 'rr_geo/locations#suggestions'
    put '/rr-geo/interests.json'       => 'rr_geo/locations#update_interests'
  end

  module ::RrGeo
    class Util
      def self.tokens_from_location(loc)
        return [] if loc.blank?
        raw = loc.to_s.downcase.strip
        words = raw.split(/[^a-z0-9]+/).select { |t| t.present? && t.length >= 3 }
        bigrams = words.each_cons(2).map { |a, b| "#{a} #{b}" }
        (words + bigrams).uniq
      end

      def self.quote_patterns(patterns)
        patterns.map { |p| ActiveRecord::Base.connection.quote(p) }.join(",")
      end

      def self.mask_ip(ip)
        return nil if ip.blank?

        addr = IPAddr.new(ip.to_s)
        if addr.ipv4?
          octets = addr.to_s.split(".")
          "#{octets[0]}.#{octets[1]}.#{octets[2]}.0"
        else
          parts = addr.hton.bytes.each_slice(2).map { |a, b| ((a << 8) + b).to_s(16) }
          "#{parts[0, 4].join(":")}::"
        end
      rescue IPAddr::InvalidAddressError
        nil
      end
    end

    module TopicQueryExtension
      # v0.4.0 — Hybrid relevance feed. Replaces the old binary geo rank with a
      # weighted score blending FOUR signals (each weight is a tunable site
      # setting), ordered DESC:
      #   (1) LOCATION  — title/tag/category matches the user's location tokens
      #   (2) AFFINITY  — content-based recommender: categories the user
      #                   tracks/watches OR has posted in (revealed interest)
      #   (3) ENGAGEMENT— coin-engine up/down votes + likes + replies + views,
      #                   log-damped so runaway threads don't dominate forever
      #   (4) FRESHNESS — recency decay so new content keeps surfacing
      # Degrades gracefully: a missing location / affinity / votes table simply
      # drops that term, so even a profile-less user still gets an
      # engagement+freshness "hot" feed instead of plain chronological.
      def latest_results(options = {})
        rel = super
        return rel unless SiteSetting.rr_geo_enabled
        return rel if options[:order].present?

        user = @guardian&.user
        return rel unless user

        w_geo   = (SiteSetting.rr_geo_weight_location   rescue 3).to_f
        w_aff   = (SiteSetting.rr_geo_weight_affinity   rescue 2).to_f
        w_eng   = (SiteSetting.rr_geo_weight_engagement rescue 2).to_f
        w_fresh = (SiteSetting.rr_geo_weight_freshness  rescue 2).to_f

        terms = []

        # (1) Location — EXISTS subqueries avoid row multiplication (no DISTINCT needed)
        tokens = ::RrGeo::Util.tokens_from_location(user.user_profile&.location)
        if tokens.present? && w_geo > 0
          q = ::RrGeo::Util.quote_patterns(tokens.map { |t| "%#{ActiveRecord::Base.sanitize_sql_like(t)}%" })
          terms << "#{w_geo} * (CASE WHEN topics.title ILIKE ANY (ARRAY[#{q}]) " \
                   "OR EXISTS (SELECT 1 FROM topic_tags tt JOIN tags tg ON tg.id = tt.tag_id WHERE tt.topic_id = topics.id AND tg.name ILIKE ANY (ARRAY[#{q}])) " \
                   "OR EXISTS (SELECT 1 FROM categories cc WHERE cc.id = topics.category_id AND cc.name ILIKE ANY (ARRAY[#{q}])) " \
                   "THEN 1 ELSE 0 END)"
        end

        # (2) Affinity (content-based recommender)
        if w_aff > 0
          aff_ids = ::RrGeo::TopicQueryExtension.affinity_category_ids(user.id)
          terms << "#{w_aff} * (CASE WHEN topics.category_id IN (#{aff_ids.join(',')}) THEN 1 ELSE 0 END)" if aff_ids.present?
        end

        # (3) Engagement (log-damped; includes coin-engine votes when present)
        use_votes = ::RrGeo::TopicQueryExtension.votes_available?
        if w_eng > 0
          vexpr = use_votes ? "3 * COALESCE(pv.vscore, 0)" : "0"
          terms << "#{w_eng} * ln(1 + GREATEST(0, #{vexpr} + 2 * COALESCE(topics.like_count, 0) + COALESCE(topics.posts_count, 0) + 0.1 * COALESCE(topics.views, 0)))"
        end

        # (4) Freshness — decays over days
        terms << "#{w_fresh} * (1.0 / (1.0 + (EXTRACT(EPOCH FROM (now() - topics.bumped_at)) / 86400.0)))" if w_fresh > 0

        # (5) LEARNED affinity — the client-side online model's distilled top
        # tags/categories (synced via /rr-geo/interests.json). This is the
        # "model running with the user": it learns from clicks/upvotes on-device,
        # we just boost topics matching what it learned.
        w_learned = (SiteSetting.rr_geo_weight_learned rescue 2).to_f
        if w_learned > 0
          prof = ::RrGeo::TopicQueryExtension.interest_profile(user)
          lparts = []
          if prof[:tags].present?
            qt = ::RrGeo::Util.quote_patterns(prof[:tags])
            lparts << "EXISTS (SELECT 1 FROM topic_tags tt3 JOIN tags tg3 ON tg3.id = tt3.tag_id WHERE tt3.topic_id = topics.id AND lower(tg3.name) IN (#{qt}))"
          end
          if prof[:categories].present?
            qc = ::RrGeo::Util.quote_patterns(prof[:categories])
            lparts << "EXISTS (SELECT 1 FROM categories cl WHERE cl.id = topics.category_id AND lower(cl.name) IN (#{qc}))"
          end
          terms << "#{w_learned} * (CASE WHEN #{lparts.join(' OR ')} THEN 1 ELSE 0 END)" if lparts.present?
        end

        # (6) EXPLORATION — a per-(user, day) pseudo-random jitter. Breaks ties and
        # gently ROTATES the feed each day so users keep discovering content
        # beyond their learned bubble (the explore/exploit tradeoff). Deterministic
        # within a day → stable across pagination; reseeds daily and per-user.
        w_explore = (SiteSetting.rr_geo_weight_explore rescue 1).to_f
        if w_explore > 0
          seed = (((Date.today.yday * 2_654_435_761) + user.id.to_i) % 100_000)
          seed = 1 if seed.zero?
          terms << "#{w_explore} * (((topics.id * #{seed}) % 997) / 997.0)"
        end

        return rel if terms.empty?

        rel = rel.joins("LEFT JOIN (SELECT topic_id, SUM(direction) AS vscore FROM coin_engine_post_votes GROUP BY topic_id) pv ON pv.topic_id = topics.id") if use_votes && w_eng > 0

        rel
          .select("topics.*, (#{terms.join(' + ')}) AS rr_feed_score")
          .reorder(Arel.sql("rr_feed_score DESC, topics.bumped_at DESC"))
      rescue StandardError => e
        Rails.logger.warn("[rr_geo] hybrid feed fell back to default: #{e.class} #{e.message}")
        rel
      end

      # Whether the coin-engine votes table exists (cached per process).
      def self.votes_available?
        return @votes_available unless @votes_available.nil?
        @votes_available = (ActiveRecord::Base.connection.table_exists?('coin_engine_post_votes') rescue false)
      end

      # Categories the user explicitly tracks/watches + categories they've posted
      # in (revealed preference). Capped + sanitized to integers for safe SQL.
      def self.affinity_category_ids(user_id)
        ids = []
        ids += (::CategoryUser.where(user_id: user_id).where('notification_level >= 2').pluck(:category_id) rescue [])
        ids += (::Topic.where(user_id: user_id).order(created_at: :desc).limit(200).pluck(:category_id) rescue [])
        ids.compact.map(&:to_i).uniq.first(50)
      rescue StandardError
        []
      end

      # Client-synced interest profile (learned top tag/category names).
      def self.interest_profile(user)
        raw = (user.custom_fields['rr_interest_profile'] rescue nil)
        return { tags: [], categories: [] } if raw.blank?
        h = (JSON.parse(raw) rescue {})
        { tags: Array(h['tags']).map(&:to_s).first(25), categories: Array(h['categories']).map(&:to_s).first(25) }
      rescue StandardError
        { tags: [], categories: [] }
      end
    end
  end

  ::TopicQuery.prepend(::RrGeo::TopicQueryExtension)

  require_dependency "application_controller"
  require "request_store"
  require "ipaddr"

  module ::RrGeo::IpTracking
    def self.prepended(base)
      base.before_action :rr_track_client_ip
    end

    private

    def rr_track_client_ip
      curr_ip = request.remote_ip
      last_ip = session[:rr_last_ip]

      RequestStore.store[:rr_client_ip] = curr_ip
      RequestStore.store[:rr_ip_changed] = last_ip.present? && last_ip != curr_ip

      session[:rr_last_ip] = curr_ip
    end
  end

  ::ApplicationController.prepend(::RrGeo::IpTracking)

  require_dependency "current_user_serializer"

  add_to_serializer(:current_user, :location) { object.user_profile&.location }

  add_to_serializer(:current_user, :location_set) { object.user_profile&.location.present? }

  add_to_serializer(:current_user, :rr_geo_tokens) do
    ::RrGeo::Util.tokens_from_location(object.user_profile&.location)
  end

  module ::RrGeo
    module CurrentUserSerializerExt
      def include_location?
        object.user_profile&.location.present?
      end

      def include_rr_geo_tokens?
        SiteSetting.rr_geo_enabled && object.user_profile&.location.present?
      end

      def include_client_ip?
        object&.staff?
      end

      def include_ip_changed?
        object&.staff?
      end
    end
  end

  ::CurrentUserSerializer.prepend(::RrGeo::CurrentUserSerializerExt)

  add_to_serializer(:current_user, :client_ip) do
    ::RrGeo::Util.mask_ip(RequestStore.store[:rr_client_ip])
  end
  add_to_serializer(:current_user, :ip_changed) { !!RequestStore.store[:rr_ip_changed] }

  add_to_serializer(:site, :client_ip) do
    ::RrGeo::Util.mask_ip(RequestStore.store[:rr_client_ip])
  end
  add_to_serializer(:site, :ip_changed) { !!RequestStore.store[:rr_ip_changed] }

  require_dependency "site_serializer"

  module ::RrGeo
    module SiteSerializerExt
      def include_client_ip?
        scope&.is_staff?
      end

      def include_ip_changed?
        scope&.is_staff?
      end
    end
  end

  ::SiteSerializer.prepend(::RrGeo::SiteSerializerExt)
end
