# frozen_string_literal: true
# name: discourse-latest-geo
# about: Location-aware relevance feed (geo + content affinity + engagement + freshness) with a click-to-edit location widget. Location is auto-detected via ipinfo.io.
# version: 0.9.0

enabled_site_setting :rr_geo_enabled

register_asset "stylesheets/common/rr-geo-feed-label.scss"

after_initialize do
  load File.expand_path('../app/controllers/rr_geo/locations_controller.rb', __FILE__)

  Discourse::Application.routes.append do
    put '/rr-geo/location.json'    => 'rr_geo/locations#update'
    get '/rr-geo/suggestions.json' => 'rr_geo/locations#suggestions'
    put '/rr-geo/interests.json'   => 'rr_geo/locations#update_interests'
  end

  module ::RrGeo
    class Util
      def self.tokens_from_location(loc)
        return [] if loc.blank?
        words = loc.to_s.downcase.split(/[^a-z0-9]+/).select { |t| t.length >= 3 }
        (words + words.each_cons(2).map { |a, b| "#{a} #{b}" }).uniq
      end

      def self.quote_patterns(patterns)
        conn = ActiveRecord::Base.connection
        patterns.map { |p| conn.quote(p) }.join(",")
      end

      def self.mask_ip(ip)
        return nil if ip.blank?
        addr = IPAddr.new(ip.to_s)
        if addr.ipv4?
          o = addr.to_s.split(".")
          "#{o[0]}.#{o[1]}.#{o[2]}.0"
        else
          parts = addr.hton.bytes.each_slice(2).map { |a, b| ((a << 8) + b).to_s(16) }
          "#{parts[0, 4].join(":")}::"
        end
      rescue IPAddr::InvalidAddressError
        nil
      end

      # SCALE: the engagement term used to LEFT JOIN an aggregate over the ENTIRE
      # coin_engine_post_votes table per request. Votes are sparse, so we cache a
      # bounded topic_id->score map for 60s (one aggregate per minute server-wide)
      # and inline it as a VALUES join instead.
      def self.votes_map
        ::Discourse.cache.fetch("rr_geo_votes_map_v1", expires_in: 60.seconds) do
          ::ActiveRecord::Base.connection.exec_query(
            "SELECT topic_id, SUM(direction)::int AS s FROM coin_engine_post_votes " \
            "GROUP BY topic_id ORDER BY ABS(SUM(direction)) DESC LIMIT 500"
          ).rows.each_with_object({}) { |r, h| h[r[0].to_i] = r[1].to_i }
        end
      rescue StandardError
        {}
      end

      def self.f(key, default)
        (SiteSetting.public_send(key) rescue default).to_f
      end

      def self.i(key, default)
        (SiteSetting.public_send(key) rescue default).to_i
      end
    end

    # Weighted multi-signal ranking layered on the default latest feed. Each
    # signal is a tunable weight; a missing signal (no location, no votes table)
    # drops its term, so the feed degrades to engagement + freshness instead of
    # failing. Returns a lazy relation -- one query, paginated by the caller.
    module TopicQueryExtension
      def latest_results(options = {})
        rel = super
        return rel unless SiteSetting.rr_geo_enabled
        return rel if options[:order].present?
        user = @guardian&.user
        return rel unless user

        u = ::RrGeo::Util
        terms = []

        # Location: title / tag / category matches the user's location tokens.
        w_geo = u.f(:rr_geo_weight_location, 3)
        tokens = u.tokens_from_location(user.user_profile&.location)
        if w_geo > 0 && tokens.present?
          q = u.quote_patterns(tokens.map { |t| "%#{ActiveRecord::Base.sanitize_sql_like(t)}%" })
          terms << "#{w_geo} * (CASE WHEN topics.title ILIKE ANY (ARRAY[#{q}]) " \
                   "OR EXISTS (SELECT 1 FROM topic_tags tt JOIN tags tg ON tg.id = tt.tag_id WHERE tt.topic_id = topics.id AND tg.name ILIKE ANY (ARRAY[#{q}])) " \
                   "OR EXISTS (SELECT 1 FROM categories cc WHERE cc.id = topics.category_id AND cc.name ILIKE ANY (ARRAY[#{q}])) THEN 1 ELSE 0 END)"
        end

        # Affinity: categories the user tracks/watches or posts in.
        w_aff = u.f(:rr_geo_weight_affinity, 2)
        if w_aff > 0
          aff_ids = affinity_category_ids(user.id)
          terms << "#{w_aff} * (CASE WHEN topics.category_id IN (#{aff_ids.join(',')}) THEN 1 ELSE 0 END)" if aff_ids.present?
        end

        # Engagement: log-damped votes + likes + replies + views.
        use_votes = votes_available?
        w_eng = u.f(:rr_geo_weight_engagement, 2)
        vmap = (use_votes && w_eng > 0) ? u.votes_map : {}
        use_votes = false if vmap.empty?
        if w_eng > 0
          vexpr = use_votes ? "3 * COALESCE(pv.vscore, 0)" : "0"
          terms << "#{w_eng} * ln(1 + GREATEST(0, #{vexpr} + 2 * COALESCE(topics.like_count, 0) + COALESCE(topics.posts_count, 0) + 0.1 * COALESCE(topics.views, 0)))"
        end

        # Freshness: decays over days.
        w_fresh = u.f(:rr_geo_weight_freshness, 2)
        terms << "#{w_fresh} * (1.0 / (1.0 + (EXTRACT(EPOCH FROM (now() - topics.bumped_at)) / 86400.0)))" if w_fresh > 0

        # Velocity: recent posting momentum, sharply decayed by hours since last post.
        w_vel = u.f(:rr_geo_weight_velocity, 3)
        if w_vel > 0
          vwin = u.i(:rr_geo_velocity_window_hours, 8)
          terms << "#{w_vel} * (CASE WHEN topics.last_posted_at > (now() - INTERVAL '#{vwin} hours') " \
                   "THEN ln(1 + GREATEST(0, COALESCE(topics.posts_count, 1) - 1)) * (1.0 / (1.0 + (EXTRACT(EPOCH FROM (now() - topics.last_posted_at)) / 3600.0))) ELSE 0 END)"
        end

        # Learned affinity: tag/category names the on-device model synced up.
        w_learned = u.f(:rr_geo_weight_learned, 2)
        if w_learned > 0
          prof = interest_profile(user)
          lparts = []
          lparts << "EXISTS (SELECT 1 FROM topic_tags tt3 JOIN tags tg3 ON tg3.id = tt3.tag_id WHERE tt3.topic_id = topics.id AND lower(tg3.name) IN (#{u.quote_patterns(prof[:tags])}))" if prof[:tags].present?
          lparts << "EXISTS (SELECT 1 FROM categories cl WHERE cl.id = topics.category_id AND lower(cl.name) IN (#{u.quote_patterns(prof[:categories])}))" if prof[:categories].present?
          terms << "#{w_learned} * (CASE WHEN #{lparts.join(' OR ')} THEN 1 ELSE 0 END)" if lparts.present?
        end

        # Seeds rotate on a time bucket: stable within a scroll session, varied
        # between visits. The bigint cast guards against int overflow on high ids.
        bucket = Time.now.to_i / ([u.i(:rr_geo_seed_bucket_minutes, 25), 5].max * 60)

        w_explore = u.f(:rr_geo_weight_explore, 1)
        if w_explore > 0
          seed = ((bucket * 2_654_435_761) + user.id) % 100_000
          seed = 1 if seed.zero?
          terms << "#{w_explore} * (((topics.id::bigint * #{seed}) % 997) / 997.0)"
        end

        # Fresh-post lottery: a recent topic gets a small chance at a large boost.
        w_fb = u.f(:rr_geo_weight_fresh_boost, 2)
        if w_fb > 0
          fwin = u.i(:rr_geo_fresh_boost_window_hours, 48)
          fchance = u.i(:rr_geo_fresh_boost_chance, 12)
          fseed = (((bucket + 7) * 40_503) + user.id) % 100_000
          fseed = 1 if fseed.zero?
          terms << "#{w_fb} * (CASE WHEN topics.created_at > (now() - INTERVAL '#{fwin} hours') AND ((topics.id::bigint * #{fseed}) % 100) < #{fchance} THEN 10 ELSE 0 END)"
        end

        return rel if terms.empty?

        if use_votes && w_eng > 0
          vals = vmap.map { |tid, sc| "(#{tid.to_i},#{sc.to_i})" }.join(",")
          rel = rel.joins("LEFT JOIN (VALUES #{vals}) AS pv(topic_id, vscore) ON pv.topic_id = topics.id")
        end
        rel.select("topics.*, (#{terms.join(' + ')}) AS rr_feed_score")
           .reorder(Arel.sql("rr_feed_score DESC, topics.bumped_at DESC"))
      rescue => e
        Rails.logger.warn("[rr_geo] feed ranking fell back to default: #{e.class} #{e.message}")
        rel
      end

      private

      # Cached once per process: does the coin-engine votes table exist?
      def votes_available?
        v = ::RrGeo::TopicQueryExtension.instance_variable_get(:@votes_available)
        return v unless v.nil?
        v = (ActiveRecord::Base.connection.table_exists?('coin_engine_post_votes') rescue false)
        ::RrGeo::TopicQueryExtension.instance_variable_set(:@votes_available, v)
        v
      end

      # Two indexed lookups per feed load otherwise; cache briefly off the hot path.
      def affinity_category_ids(user_id)
        Discourse.cache.fetch("rr_geo_aff_#{user_id}", expires_in: 5.minutes) do
          ids = (::CategoryUser.where(user_id: user_id).where('notification_level >= 2').pluck(:category_id) rescue [])
          ids += (::Topic.where(user_id: user_id).order(created_at: :desc).limit(200).pluck(:category_id) rescue [])
          ids.compact.map(&:to_i).uniq.first(50)
        end
      rescue
        []
      end

      def interest_profile(user)
        raw = (user.custom_fields['rr_interest_profile'] rescue nil)
        return { tags: [], categories: [] } if raw.blank?
        h = (JSON.parse(raw) rescue {})
        { tags: Array(h['tags']).map(&:to_s).first(25), categories: Array(h['categories']).map(&:to_s).first(25) }
      rescue
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
      RequestStore.store[:rr_client_ip] = curr_ip
      RequestStore.store[:rr_ip_changed] = session[:rr_last_ip].present? && session[:rr_last_ip] != curr_ip
      session[:rr_last_ip] = curr_ip
    end
  end

  ::ApplicationController.prepend(::RrGeo::IpTracking)

  require_dependency "current_user_serializer"

  add_to_serializer(:current_user, :location) { object.user_profile&.location }
  add_to_serializer(:current_user, :location_set) { object.user_profile&.location.present? }
  add_to_serializer(:current_user, :rr_geo_tokens) { ::RrGeo::Util.tokens_from_location(object.user_profile&.location) }

  module ::RrGeo
    module CurrentUserSerializerExt
      def include_location?;       object.user_profile&.location.present?; end
      def include_rr_geo_tokens?;  SiteSetting.rr_geo_enabled && object.user_profile&.location.present?; end
      def include_client_ip?;      object&.staff?; end
      def include_ip_changed?;     object&.staff?; end
    end
  end

  ::CurrentUserSerializer.prepend(::RrGeo::CurrentUserSerializerExt)

  add_to_serializer(:current_user, :client_ip)  { ::RrGeo::Util.mask_ip(RequestStore.store[:rr_client_ip]) }
  add_to_serializer(:current_user, :ip_changed) { !!RequestStore.store[:rr_ip_changed] }
  add_to_serializer(:site, :client_ip)  { ::RrGeo::Util.mask_ip(RequestStore.store[:rr_client_ip]) }
  add_to_serializer(:site, :ip_changed) { !!RequestStore.store[:rr_ip_changed] }

  require_dependency "site_serializer"

  module ::RrGeo
    module SiteSerializerExt
      def include_client_ip?;  scope&.is_staff?; end
      def include_ip_changed?; scope&.is_staff?; end
    end
  end

  ::SiteSerializer.prepend(::RrGeo::SiteSerializerExt)
end
