# frozen_string_literal: true
# name: discourse-latest-geo
# about: Location-aware relevance feed (geo + content affinity + engagement + freshness) with a click-to-edit location widget. Location is auto-detected from the platform's Cloudflare edge geolocation, falling back to ipinfo.io.
# version: 0.15.0

# v0.10.0 perf refactor:
#   * NO per-row string matching in the feed query. Geo + learned-interest
#     matches are resolved to bounded topic-id sets with one-shot indexed
#     queries (cached 5 min per user) and inlined as a VALUES join.
#   * Ranking horizon: full scoring only runs for topics bumped within
#     rr_geo_rank_horizon_days; the long tail short-circuits to 0 and falls
#     back to bumped order (where it would have landed anyway).
#   * Per-(user, seed-bucket) feed cache: the feed is stable within a seed
#     bucket BY DESIGN, so the first rr_geo_cache_topics ranked ids are cached
#     in Redis and pagination is served from the cache. Bucket expiry is the
#     invalidation.
#   * Learned interests are now WEIGHTED (client syncs model weights, server
#     boosts proportionally). Backward compatible with v0.5 plain-name lists.
#   * GET /rr-geo/prior.json — anon-safe cold-start prior (top tags among
#     geo-matching topics) used to seed fresh client models.
#   * Optional write-time city auto-tagging job (rr_geo_auto_tag_cities,
#     default OFF) so local topics that name their city anywhere in the first
#     post become geo-matchable via indexed tags.

# v0.11.0 structured graded geo:
#   * Location is now structured "City, Province/State, Country" (required on
#     save; legacy two-part values keep working until next edit).
#   * GRADED PROXIMITY: geo boost is no longer binary. Own city scores 1.0,
#     curated nearby cities 0.7, province/state 0.45, country 0.2 — so a town
#     with no posts of its own still gets a locally-relevant feed instead of
#     falling back to nothing.

# v0.13.0 recommendation hub:
#   * ::RrGeo::SignalHub — canonical cross-plugin read API for every
#     personalization signal (geo tokens, graded geo levels, learned interest
#     profile, coin-engine follows, vote map). discourse-shorts now ranks with
#     these instead of private copies; future surfaces should too.
#   * SOCIAL feed signal: topics authored by people the user follows
#     (coin-engine graph) get a weighted boost — mirrors the shorts rail's
#     strongest signal. New setting rr_geo_weight_social.
#   * Client: window.rrRec public scoring/learning API + opt-in device-GPS
#     location button (ipinfo auto-detect unchanged and still the default).

# v0.14.0 geo mesh:
#   * REAL GEOFENCING: the curated 27-city NEARBY_CITIES map is now only a
#     hand-tuned overlay. ::RrGeo::GeoMesh radius-geofences nearby localities
#     for ANY Canada/US town: ~19.8K GeoNames localities (CC BY 4.0) with
#     lat/lon centroids, haversine over a lat-sorted window, memoized.
#     Settings: rr_geo_nearby_radius_km (50), rr_geo_nearby_limit (14).
#   * Location typeahead searches the full mesh (any town, Canada-first
#     ranking) instead of a 50-city static list.
#   * Privacy unchanged: mesh uses locality centroids only; user coordinates
#     are never stored.
#   * v0.14.1 BAR REDESIGN: rr-geo-bar engagement surface. One-click
#     "Use my location" GPS button lives IN the collapsed bar (no editor
#     hop), pulsing-pin unset CTA, success flash, card-style editor with
#     GPS-first layout, full mobile (<=600px) breakpoint, reduced-motion
#     support. Bar visuals are now fully plugin-owned (root class renamed
#     from rr-geo-feed-label to rr-geo-bar; old theme banner CSS is inert).

# v0.15.0 cloudflare-first geolocation:
#   * The platform is a geo source now: GET /rr-geo/detect.json returns the
#     visitor's location read from Cloudflare's visitor-location headers
#     (CF-IPCity / CF-Region / CF-IPCountry / ... — set by the fronting
#     Worker from request.cf, or by the zone's "Add visitor location headers"
#     managed transform on any CF-proxied install). rr_geo_source picks the
#     policy: auto (default — cloudflare when the platform answers, ipinfo.io
#     otherwise), cloudflare, ipinfo.
#   * The client bootstraps from the edge by default: no third-party call, no
#     ad-block breakage, no ipinfo quota — and the masked client ip is set for
#     EVERY visitor (ipinfo's echo only ever fed lastIp via the staff-gated
#     serializer), so network-change detection finally works for everyone.
#   * Manual profile locations are never clobbered: the v0.11.2 self-correct
#     guard was skippable (onlyIfBlank:false — the only call site) and silently
#     overwrote hand-typed locations with IP geo; it now only ever rewrites a
#     value it auto-set itself.

enabled_site_setting :rr_geo_enabled

register_asset "stylesheets/common/rr-geo-feed-label.scss"

after_initialize do

  require "request_store"
  require "ipaddr"
  require "digest"

  # Expose the (cached, topics.excerpt column) first-post excerpt on every
  # topic-list item — core only includes it for pinned topics. Powers the
  # desktop row kit's excerpt line.
  add_to_serializer(:topic_list_item, :rr_excerpt, include_condition: -> { SiteSetting.rr_geo_enabled }) do
    object.excerpt
  end
  load File.expand_path('../app/controllers/rr_geo/locations_controller.rb', __FILE__)
  load File.expand_path('../lib/rr_geo/geo_mesh.rb', __FILE__)

  Discourse::Application.routes.append do
    put '/rr-geo/location.json'    => 'rr_geo/locations#update'
    get '/rr-geo/suggestions.json' => 'rr_geo/locations#suggestions'
    put '/rr-geo/interests.json'   => 'rr_geo/locations#update_interests'
    get '/rr-geo/prior.json'       => 'rr_geo/locations#prior'
    get '/rr-geo/detect.json'      => 'rr_geo/locations#detect'
  end

  module ::RrGeo
    class Util
      # Memoized per request — called from the ranker AND two serializers.
      # Standalone words too generic to be a useful geo signal (they match
      # unrelated content). Kept only inside multi-word phrases ("new york").
      GEO_STOPWORDS = %w[new north south east west upper lower central united
                         states state province county region city town village
                         the of and les des].freeze

      def self.tokens_from_location(loc)
        return [] if loc.blank?
        memo = (RequestStore.store[:rr_geo_tok_memo] ||= {})
        memo[loc] ||= begin
          out = []
          # Location is "City, Region, Country" — tokenize WITHIN each comma
          # segment so we never build cross-boundary garbage like "york united".
          loc.to_s.downcase.split(',').each do |seg|
            words = seg.split(/[^a-z0-9]+/).select { |t| t.length >= 3 }
            next if words.empty?
            out << words.join(' ') if words.length >= 2            # full segment phrase
            words.each_cons(2) { |a, b| out << "#{a} #{b}" } if words.length > 2
            words.each { |w| out << w unless GEO_STOPWORDS.include?(w) }  # non-generic singles
          end
          out.uniq.reject(&:empty?)
        end
      end

      # ---- v0.11: structured location + graded proximity ------------------
      # Curated nearby-city map (lowercased). Easy to extend; misses simply
      # fall through to the province level.
      NEARBY_CITIES = {
        "toronto"       => ["mississauga", "vaughan", "markham", "richmond hill", "etobicoke", "scarborough", "north york", "east york", "brampton", "pickering"],
        "mississauga"   => ["toronto", "brampton", "oakville", "milton", "etobicoke"],
        "brampton"      => ["mississauga", "vaughan", "caledon", "toronto", "orangeville"],
        "orangeville"   => ["caledon", "brampton", "shelburne", "erin", "mono", "alliston"],
        "caledon"       => ["orangeville", "brampton", "bolton", "erin"],
        "hamilton"      => ["burlington", "ancaster", "dundas", "stoney creek", "grimsby"],
        "vaughan"       => ["toronto", "richmond hill", "markham", "king city", "brampton"],
        "markham"       => ["richmond hill", "scarborough", "stouffville", "vaughan", "toronto"],
        "richmond hill" => ["markham", "vaughan", "aurora", "thornhill"],
        "oakville"      => ["burlington", "mississauga", "milton"],
        "burlington"    => ["oakville", "hamilton", "milton", "waterdown"],
        "oshawa"        => ["whitby", "courtice", "bowmanville", "ajax"],
        "whitby"        => ["oshawa", "ajax", "pickering", "brooklin"],
        "ajax"          => ["pickering", "whitby", "oshawa"],
        "pickering"     => ["ajax", "scarborough", "whitby"],
        "newmarket"     => ["aurora", "east gwillimbury", "bradford", "richmond hill"],
        "aurora"        => ["newmarket", "richmond hill", "king city"],
        "barrie"        => ["innisfil", "orillia", "angus", "alliston"],
        "kitchener"     => ["waterloo", "cambridge", "guelph"],
        "waterloo"      => ["kitchener", "cambridge", "guelph"],
        "guelph"        => ["kitchener", "waterloo", "cambridge", "erin"],
        "london"        => ["st. thomas", "strathroy", "woodstock"],
        "ottawa"        => ["gatineau", "kanata", "orleans", "nepean"],
        "vancouver"     => ["burnaby", "richmond", "surrey", "north vancouver", "coquitlam"],
        "calgary"       => ["airdrie", "okotoks", "cochrane", "chestermere"],
        "edmonton"      => ["st. albert", "sherwood park", "leduc", "spruce grove"],
        "montreal"      => ["laval", "longueuil", "brossard"],
      }.freeze

      def self.location_parts(loc)
        parts = loc.to_s.split(',').map { |p| p.strip.downcase }.reject(&:blank?)
        { city: parts[0], province: parts[1], country: parts[2] }
      end

      def self.tokenize_piece(piece)
        return [] if piece.blank?
        words = piece.to_s.downcase.split(/[^a-z0-9]+/).select { |t| t.length >= 3 }
        (words + words.each_cons(2).map { |a, b| "#{a} #{b}" }).uniq
      end

      # v0.14: tokens for NEARBY place names. Stricter than tokenize_piece:
      # multi-word places match as the FULL PHRASE only ("richmond hill" must
      # not emit bare "hill" — or "richmond", which would false-match
      # Richmond BC), and generic single-word locality names ("Downtown",
      # "City Park") are dropped entirely — a 0.7-weight ILIKE on %park%
      # would geo-boost half the forum.
      NEARBY_GENERIC = (GEO_STOPWORDS + %w[
        downtown uptown midtown business district core neighbourhood
        neighbourhoods park parks heights mission beach lake hill hills creek
        river falls springs gardens garden grove point bay mount mills valley
        view ridge crossing junction station place court estates
      ]).freeze

      def self.tokenize_nearby(name)
        words = name.to_s.downcase.split(/[^a-z0-9]+/).select { |t| t.length >= 3 }
        return [] if words.empty?
        return [words.join(' ')] if words.length > 1
        NEARBY_GENERIC.include?(words[0]) ? [] : words
      end

      # [[tokens, weight], ...] — own city 1.0, nearby 0.7, province 0.45,
      # country 0.2. Legacy "City, Province" values simply have no country level.
      def self.leveled_tokens(loc)
        p = location_parts(loc)
        levels = []
        levels << [tokenize_piece(p[:city]), 1.0] if p[:city].present?
        if p[:city].present?
          near = (NEARBY_CITIES[p[:city]] || [])
          # v0.14: GEO MESH — radius geofence for ANY town. The curated map
          # above stays as a hand-tuned overlay (GTA core quality); the mesh
          # makes "nearby" real everywhere else (Moncton, Missoula, ...).
          if defined?(::RrGeo::GeoMesh)
            mesh = begin
              ::RrGeo::GeoMesh.neighbors(
                p[:city], p[:province],
                radius_km: i(:rr_geo_nearby_radius_km, 50),
                limit: i(:rr_geo_nearby_limit, 14)
              )
            rescue StandardError
              []
            end
            near = (near + mesh.map { |n, _a, _d| n.downcase }).uniq
          end
          near_toks = near.flat_map { |n| tokenize_nearby(n) }.uniq
          levels << [near_toks, 0.7] if near_toks.present?
        end
        levels << [tokenize_piece(p[:province]), 0.45] if p[:province].present?
        levels << [tokenize_piece(p[:country]), 0.2] if p[:country].present?
        levels
      end

      def self.quote_patterns(patterns)
        conn = ActiveRecord::Base.connection
        patterns.map { |p| conn.quote(p) }.join(",")
      end

      # True client IP. Behind Cloudflare, request.remote_ip resolves to the CF
      # EDGE ip (and rotates per request across CF's pool), which broke geo,
      # per-IP rate limiting and abuse logging. CF sets CF-Connecting-IP to the
      # real client and overwrites any client-supplied value, so it's safe to
      # trust as long as the origin only serves CF traffic. Falls back to the
      # XFF head, then remote_ip. (Proper fix is reverse-proxy trust config in
      # app.yml; this makes the plugin correct regardless.)
      def self.real_ip(request)
        cf = request.get_header('HTTP_CF_CONNECTING_IP').to_s.strip
        return cf unless cf.empty?
        tc = request.get_header('HTTP_TRUE_CLIENT_IP').to_s.strip
        return tc unless tc.empty?
        xff = request.get_header('HTTP_X_FORWARDED_FOR').to_s.split(',').first.to_s.strip
        return xff unless xff.empty?
        request.remote_ip
      rescue StandardError
        request.remote_ip
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

      # ---- v0.15: Cloudflare edge geolocation ------------------------------
      # On a Cloudflare-powered platform every request already carries the
      # visitor's location, resolved at the edge: the fronting Worker sets
      # these headers from request.cf (and any plain CF-proxied install gets
      # the same names from the "Add visitor location headers" managed
      # transform). Reading them is free, instant, needs no third-party quota
      # and cannot be ad-blocked. Best-effort geo, never a security input.
      # Non-ASCII values (Montréal) arrive percent-encoded by convention.
      CF_GEO_HEADERS = {
        city:        'HTTP_CF_IPCITY',
        region:      'HTTP_CF_REGION',
        region_code: 'HTTP_CF_REGION_CODE',
        country:     'HTTP_CF_IPCOUNTRY',
        timezone:    'HTTP_CF_TIMEZONE',
        postal:      'HTTP_CF_POSTAL_CODE',
      }.freeze

      def self.cf_geo(request)
        out = {}
        CF_GEO_HEADERS.each do |key, header|
          v = request.get_header(header).to_s.dup.force_encoding(Encoding::UTF_8)
          next unless v.valid_encoding?
          v = (URI.decode_www_form_component(v) rescue v) if v.include?('%')
          v = v.strip
          out[key] = v if v.present? && v.length <= 100
        end
        # XX = Cloudflare could not resolve a country; T1 = a Tor exit node.
        out.delete(:country) if %w[XX T1].include?(out[:country])
        out.presence
      rescue StandardError
        nil
      end

      # SCALE: votes come from a bounded topic_id->score map cached 60s
      # (one aggregate per minute server-wide), inlined as a VALUES join.
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

      # v0.10: weighted profile — entries normalize to [name, weight 0..1].
      # Accepts v0.5 plain-name arrays, "name|w" strings, pairs, and hashes.
      # v0.13: lives on Util so SignalHub can expose it cross-plugin.
      def self.interest_profile(user)
        raw = (user.custom_fields['rr_interest_profile'] rescue nil)
        return { tags: [], categories: [] } if raw.blank?
        h = (JSON.parse(raw) rescue {})
        norm = lambda do |arr|
          Array(arr).map do |e|
            if e.is_a?(Array)
              [e[0].to_s, (e[1] || 1).to_f]
            elsif e.is_a?(Hash)
              [(e['name'] || e[:name]).to_s, (e['w'] || e[:w] || 1).to_f]
            else
              s = e.to_s
              if s.include?('|')
                n, w = s.split('|', 2)
                [n, w.to_f]
              else
                [s, 1.0]
              end
            end
          end.reject { |n, _| n.blank? }.first(25)
        end
        { tags: norm.call(h['tags']), categories: norm.call(h['categories']) }
      rescue
        { tags: [], categories: [] }
      end

      def self.f(key, default)
        (SiteSetting.public_send(key) rescue default).to_f
      end

      def self.i(key, default)
        (SiteSetting.public_send(key) rescue default).to_i
      end

      # ---- v0.10: boost prefetch ------------------------------------------
      # Resolves the user's geo tokens + learned interests to BOUNDED
      # topic-id boost sets OUTSIDE the feed query. Cached 5 min per user;
      # cache key shifts when location or interest profile changes.
      # Returns { map: {topic_id => [geo_hit, learned_w]},
      #           geo_cat_ids: [int], learned_cats: {cat_id => w}, digest: }
      def self.user_boosts(user, prof, horizon_days)
        loc = user.user_profile&.location.to_s
        # v0.13: follows feed the social signal AND the digest, so the cached
        # feed window invalidates when the user's social graph changes.
        followed = ::RrGeo::SignalHub.followed_ids(user)
        digest = Digest::MD5.hexdigest(
          [loc, prof.to_json, horizon_days, i(:rr_geo_match_limit, 400),
           followed.length, followed.first(50).join(',')].join('|')
        )[0, 12]
        cached = ::Discourse.cache.fetch("rr_geo_boost_v1_#{user.id}_#{digest}", expires_in: 5.minutes) do
          build_boosts(loc, prof, horizon_days)
        end
        (cached || empty_boosts).merge(digest: digest, followed: followed)
      rescue StandardError
        empty_boosts.merge(digest: 'none', followed: [])
      end

      def self.empty_boosts
        { map: {}, geo_cats: {}, learned_cats: {} }
      end

      def self.build_boosts(loc, prof, horizon_days)
        conn = ActiveRecord::Base.connection
        lim = i(:rr_geo_match_limit, 400).clamp(50, 2000)
        horizon = "bumped_at > (now() - INTERVAL '#{horizon_days.to_i} days')"
        # v0.12: location content is EVERGREEN -- a Montreal contractor listing is
        # relevant no matter when it was last bumped. The 60-day rank horizon was
        # hiding ~90% of local topics (dormant directory/jobs listings) from the geo
        # booster, so a Montreal user saw ZERO local posts while search found ~500.
        # Match geo over a much wider window; keep the tight horizon for learned signals.
        geo_days = i(:rr_geo_match_horizon_days, 1095).clamp(60, 3650)
        geo_horizon = "bumped_at > (now() - INTERVAL '#{geo_days} days')"
        map = {}
        geo_cats = {}

        # v0.11: graded proximity — each level writes its weight into the
        # boost map; a stronger (closer) level always wins via max().
        leveled_tokens(loc).each do |tokens, weight|
          next if tokens.blank?
          pats = quote_patterns(tokens.map { |t| "%#{ActiveRecord::Base.sanitize_sql_like(t)}%" })

          # Titles: bounded scans over the horizon window, once per 5 min.
          conn.select_values(
            "SELECT id FROM topics WHERE deleted_at IS NULL AND visible " \
            "AND #{geo_horizon} AND title ILIKE ANY (ARRAY[#{pats}]) LIMIT #{lim}"
          ).each do |id|
            cell = (map[id.to_i] ||= [0.0, 0.0])
            cell[0] = [cell[0], weight].max
          end

          # Tags: exact lowercase match (indexed), incl. hyphen variants.
          variants = tokens.flat_map { |t| [t, t.tr(' ', '-')] }.uniq
          qnames = variants.map { |v| conn.quote(v) }.join(',')
          conn.select_values(
            "SELECT tt.topic_id FROM topic_tags tt " \
            "JOIN tags tg ON tg.id = tt.tag_id " \
            "JOIN topics t ON t.id = tt.topic_id " \
            "WHERE lower(tg.name) IN (#{qnames}) AND t.deleted_at IS NULL " \
            "AND t.visible AND t.#{geo_horizon} LIMIT #{lim}"
          ).each do |id|
            cell = (map[id.to_i] ||= [0.0, 0.0])
            cell[0] = [cell[0], weight].max
          end

          # Categories stay a weighted per-row CASE — no materialization needed.
          conn.select_values(
            "SELECT id FROM categories WHERE name ILIKE ANY (ARRAY[#{pats}])"
          ).map(&:to_i).first(25).each do |cid|
            geo_cats[cid] = [geo_cats[cid] || 0.0, weight].max
          end
        end

        learned_cats = {}
        if prof[:tags].present?
          vals = prof[:tags].map { |n, w| "(#{conn.quote(n.to_s.downcase)},#{w.to_f.clamp(0.0, 1.0).round(2)})" }.join(',')
          conn.select_rows(
            "SELECT tt.topic_id, MAX(v.w) FROM (VALUES #{vals}) v(name, w) " \
            "JOIN tags tg ON lower(tg.name) = v.name " \
            "JOIN topic_tags tt ON tt.tag_id = tg.id " \
            "JOIN topics t ON t.id = tt.topic_id " \
            "WHERE t.deleted_at IS NULL AND t.visible AND t.#{horizon} " \
            "GROUP BY tt.topic_id LIMIT #{lim}"
          ).each do |tid, w|
            cell = (map[tid.to_i] ||= [0, 0.0])
            cell[1] = [cell[1], w.to_f].max
          end
        end
        if prof[:categories].present?
          qn = prof[:categories].map { |n, _| conn.quote(n.to_s.downcase) }.join(',')
          wmap = prof[:categories].each_with_object({}) { |(n, w), h| h[n.to_s.downcase] = w.to_f.clamp(0.0, 1.0).round(2) }
          conn.select_rows("SELECT id, lower(name) FROM categories WHERE lower(name) IN (#{qn})").each do |id, nm|
            learned_cats[id.to_i] = wmap[nm] || 1.0
          end
        end

        { map: map, geo_cats: geo_cats, learned_cats: learned_cats }
      end
    end

    # ---- v0.13: SIGNAL HUB -----------------------------------------------
    # Canonical, cross-plugin READ API for every personalization signal this
    # plugin owns. discourse-shorts (and any future surface: FAB hub, related
    # topics, digests) should rank with THESE instead of growing private
    # copies — one user model, many surfaces. Every method degrades to an
    # empty value instead of raising, so callers never need their own rescue.
    class SignalHub
      # Flat tokenized location: ["orangeville", "orangeville ontario", ...]
      def self.geo_tokens(user)
        Util.tokens_from_location(user&.user_profile&.location)
      rescue StandardError
        []
      end

      # Graded geo levels: [[tokens, weight], ...] with own city 1.0,
      # curated nearby 0.7, province/state 0.45, country 0.2.
      def self.leveled_geo(user)
        Util.leveled_tokens(user&.user_profile&.location.to_s)
      rescue StandardError
        []
      end

      # Learned interests synced by the client model:
      # { tags: [[name, w 0..1], ...], categories: [[name, w 0..1], ...] }
      def self.interest_profile(user)
        return { tags: [], categories: [] } unless user
        Util.interest_profile(user)
      rescue StandardError
        { tags: [], categories: [] }
      end

      # Coin-engine social graph: user ids this user follows (cached 5 min).
      def self.followed_ids(user)
        return [] unless user
        ::Discourse.cache.fetch("rr_geo_followed_v1_#{user.id}", expires_in: 5.minutes) do
          if defined?(::DiscourseCoinEngine::Follow)
            ::DiscourseCoinEngine::Follow.where(follower_id: user.id)
              .limit(500).pluck(:following_id).map(&:to_i)
          else
            []
          end
        end || []
      rescue StandardError
        []
      end

      # Bounded topic_id => net-vote map (coin-engine post votes, 60s cache).
      def self.votes_map
        Util.votes_map
      end
    end

    # Weighted multi-signal ranking layered on the default latest feed.
    # v0.10: hot query contains ONLY integer/float arithmetic + small VALUES
    # joins; horizon-bounded; results served from a per-bucket cache.
    module TopicQueryExtension
      def latest_results(options = {})
        rel = super
        return rel unless SiteSetting.rr_geo_enabled
        return rel if options[:order].present?
        user = @guardian&.user
        return rel unless user

        u = ::RrGeo::Util
        horizon = u.i(:rr_geo_rank_horizon_days, 60).clamp(1, 3650)
        bucket_min = [u.i(:rr_geo_seed_bucket_minutes, 25), 5].max
        bucket = Time.now.to_i / (bucket_min * 60)

        prof = interest_profile(user)
        boosts = u.user_boosts(user, prof, horizon)

        # ---- per-(user, bucket) ranked-window cache ----
        if SiteSetting.rr_geo_cache_enabled && rr_cacheable?(options)
          per_page = (options[:per_page] || SiteSetting.topics_per_page).to_i
          per_page = 30 if per_page <= 0
          offset = options[:page].to_i * per_page
          cache_n = u.i(:rr_geo_cache_topics, 150).clamp(30, 500)

          if offset + per_page <= cache_n
            key = "rr_geo_feed_v2_#{user.id}_#{bucket}_#{boosts[:digest]}_#{horizon}"
            ids = ::Discourse.cache.fetch(key, expires_in: bucket_min.minutes) do
              scored = rr_apply_score(rel.except(:limit, :offset), boosts, horizon, bucket, user)
              if scored
                ActiveRecord::Base.connection
                  .select_values("SELECT id FROM (#{scored.limit(cache_n).to_sql}) rr_window")
                  .map(&:to_i)
              else
                []
              end
            end
            # v0.11.1: return the FULL cached id window as one ordered
            # relation and let core paginate it. TopicQuery#create_list runs
            # prioritize_pinned_topics on our result, which RE-APPLIES the
            # page offset (`unpinned_topics.offset(page*per_page - pinned)`),
            # so returning a pre-sliced page made every page > 0 come back
            # empty (offset 30 over a 30-row relation). Keep rel's limit —
            # core's page-0 branch slices `[0...limit]` and the page-N branch
            # relies on the relation's limit after replacing the offset.
            if ids.present? && ids.length > offset
              woven = rr_weave_local(ids, boosts)
              return rel.except(:offset)
                        .where("topics.id IN (?)", woven)
                        .reorder(Arel.sql(
                          "array_position(ARRAY[#{woven.join(',')}]::int[], topics.id)"
                        ))
            end
            # ids ran short of the requested page => genuinely past the end
            # of the listable set; fall through to the live path.
          end
        end

        rr_apply_score(rel, boosts, horizon, bucket, user) || rel
      rescue => e
        Rails.logger.warn("[rr_geo] feed ranking fell back to default: #{e.class} #{e.message}")
        rel
      end

      private

      # v0.12: GUARANTEE local representation. Geo is a soft score term, so when a
      # user's local content is mostly dormant it never out-scores fresh topics and
      # they see zero local posts. Splice the top geo-matched topics (highest graded
      # hit) into early, spread feed slots if they aren't already near the top.
      def rr_weave_local(ids, boosts)
        floor = ::RrGeo::Util.i(:rr_geo_local_floor, 4)
        return ids if floor <= 0
        geo = (boosts[:map] || {}).select { |_, (g, _)| g.to_f > 0 }
                                  .sort_by { |_, (g, _)| -g.to_f }.map { |id, _| id.to_i }
        return ids if geo.blank?
        present = ids.first(60).to_set
        inject = geo.reject { |gid| present.include?(gid) }.first(floor)
        return ids if inject.blank?
        out = ids.dup
        inject.each_with_index { |gid, k| out.insert([4 + k * 5, out.length].min, gid) }
        out.uniq
      end

      def rr_cacheable?(options)
        options[:category].blank? && options[:tags].blank? &&
          options[:topic_ids].blank? && options[:q].blank? &&
          options[:skip_ordering].blank? && options[:include_muted].nil?
      end

      # Builds the scored relation. Returns nil when no signal applies.
      def rr_apply_score(rel, boosts, horizon_days, bucket, user)
        u = ::RrGeo::Util
        terms = []
        has_boost_join = boosts[:map].present?

        # Location: prefetched GRADED hit (1.0 own city .. 0.2 country) OR
        # weighted category membership.
        w_geo = u.f(:rr_geo_weight_location, 3)
        if w_geo > 0
          parts = []
          parts << "COALESCE(rrb.geo_hit, 0)" if has_boost_join
          if boosts[:geo_cats].present?
            whens = boosts[:geo_cats].map { |cid, w| "WHEN #{cid.to_i} THEN #{w.to_f.round(2)}" }.join(' ')
            parts << "(CASE topics.category_id #{whens} ELSE 0 END)"
          end
          terms << "#{w_geo} * GREATEST(#{parts.join(', ')})" if parts.present?
        end

        # Affinity: categories the user tracks/watches or posts in.
        w_aff = u.f(:rr_geo_weight_affinity, 2)
        if w_aff > 0
          aff_ids = affinity_category_ids(user.id)
          terms << "#{w_aff} * (CASE WHEN topics.category_id IN (#{aff_ids.join(',')}) THEN 1 ELSE 0 END)" if aff_ids.present?
        end

        # v0.13 Social: topics authored by people the user follows
        # (coin-engine graph) — the shorts rail's strongest signal, now
        # unified into the forum feed. Pure integer CASE, no extra join.
        w_social = u.f(:rr_geo_weight_social, 2)
        if w_social > 0 && boosts[:followed].present?
          fids = boosts[:followed].first(200).map(&:to_i).join(',')
          terms << "#{w_social} * (CASE WHEN topics.user_id IN (#{fids}) THEN 1 ELSE 0 END)"
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

        # Learned interests: WEIGHTED — prefetched per-topic max tag weight OR
        # per-category weight, boost proportional to the client model's confidence.
        w_learned = u.f(:rr_geo_weight_learned, 2)
        if w_learned > 0
          parts = []
          parts << "COALESCE(rrb.learned_w, 0)" if has_boost_join
          if boosts[:learned_cats].present?
            whens = boosts[:learned_cats].map { |cid, w| "WHEN #{cid.to_i} THEN #{w.to_f.round(2)}" }.join(' ')
            parts << "(CASE topics.category_id #{whens} ELSE 0 END)"
          end
          terms << "#{w_learned} * GREATEST(#{parts.join(', ')})" if parts.present?
        end

        # Explore jitter: stable within a seed bucket, varied between visits.
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

        return nil if terms.empty?

        if use_votes && w_eng > 0
          vals = vmap.map { |tid, sc| "(#{tid.to_i},#{sc.to_i})" }.join(",")
          rel = rel.joins("LEFT JOIN (VALUES #{vals}) AS pv(topic_id, vscore) ON pv.topic_id = topics.id")
        end
        if has_boost_join
          vals = boosts[:map].map { |tid, (g, lw)| "(#{tid.to_i},#{g.to_f.round(2)},#{lw.to_f.round(2)})" }.join(",")
          rel = rel.joins("LEFT JOIN (VALUES #{vals}) AS rrb(topic_id, geo_hit, learned_w) ON rrb.topic_id = topics.id")
        end

        # Horizon: the long tail scores 0 without evaluating any signal and
        # falls back to bumped order — exactly where it would have landed.
        score = "CASE WHEN topics.bumped_at > (now() - INTERVAL '#{horizon_days.to_i} days') THEN (#{terms.join(' + ')}) ELSE 0 END"
        rel.select("topics.*, (#{score}) AS rr_feed_score")
           .reorder(Arel.sql("rr_feed_score DESC, topics.bumped_at DESC"))
      end

      # Cached once per process: does the coin-engine votes table exist?
      def votes_available?
        v = ::RrGeo::TopicQueryExtension.instance_variable_get(:@votes_available)
        return v unless v.nil?
        v = (ActiveRecord::Base.connection.table_exists?('coin_engine_post_votes') rescue false)
        ::RrGeo::TopicQueryExtension.instance_variable_set(:@votes_available, v)
        v
      end

      def affinity_category_ids(user_id)
        Discourse.cache.fetch("rr_geo_aff_#{user_id}", expires_in: 5.minutes) do
          ids = (::CategoryUser.where(user_id: user_id).where('notification_level >= 2').pluck(:category_id) rescue [])
          ids += (::Topic.where(user_id: user_id).order(created_at: :desc).limit(200).pluck(:category_id) rescue [])
          ids.compact.map(&:to_i).uniq.first(50)
        end
      rescue
        []
      end

      # v0.13: normalization now lives in Util (exposed via SignalHub).
      def interest_profile(user)
        ::RrGeo::Util.interest_profile(user)
      end
    end
  end

  ::TopicQuery.prepend(::RrGeo::TopicQueryExtension)

  # ---- v0.10: optional write-time city auto-tagging ------------------------
  # Default OFF. Tags recent topics with detected city names so geo matching
  # rides the indexed tag path AND local topics that only name their city in
  # the body become geo-matchable.
  class ::Jobs::RrGeoAutoTagCities < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      return unless SiteSetting.rr_geo_enabled
      return unless (SiteSetting.rr_geo_auto_tag_cities rescue false)

      cities = ::RrGeo::LocationsController::COMMON_CITIES
        .map { |c| c.split(',').first.to_s.strip.downcase }
        .select { |c| c.length >= 4 }
        .uniq

      guardian = Guardian.new(Discourse.system_user)
      Topic.where('topics.created_at > ?', 2.days.ago)
           .where(deleted_at: nil, visible: true, archetype: 'regular')
           .limit(500)
           .find_each do |topic|
        text = +"#{topic.title} "
        text << topic.first_post.raw.to_s[0, 2000] if topic.first_post
        text.downcase!
        hits = cities.select { |c| text.include?(c) }.first(2)
        next if hits.empty?
        tag_names = hits.map { |c| c.tr(' ', '-') }
        existing = topic.tags.pluck(:name)
        next if (tag_names - existing).empty?
        begin
          DiscourseTagging.tag_topic_by_names(topic, guardian, (existing + tag_names).uniq, append: true)
        rescue StandardError
          nil
        end
      end
    end
  end

  require_dependency "application_controller"

  module ::RrGeo::IpTracking
    def self.prepended(base)
      base.before_action :rr_track_client_ip
    end

    private

    def rr_track_client_ip
      # REQUEST-SCOPED ONLY — never touch the session. Writing session[:rr_last_ip]
      # on every request (this is a before_action on ALL controllers, anon included)
      # forced a Set-Cookie: _forum_session on anonymous GETs, which made Discourse
      # SKIP its anonymous page cache (x-discourse-cached: skip) and blocked CDN
      # edge caching site-wide — the dominant anon-TTFB cost. ip_changed only ever
      # fed the geo hard-reload, which was removed (now a soft no-op), so no
      # cross-request change detection is needed. RequestStore is per-request,
      # cookie-free, and safe for cached responses.
      RequestStore.store[:rr_client_ip] = ::RrGeo::Util.real_ip(request)
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
