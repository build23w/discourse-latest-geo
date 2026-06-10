# frozen_string_literal: true

# v0.14: GEO MESH — real geofenced "nearby" for ANY North American town.
# Replaces the curated 27-city NEARBY_CITIES map as the only nearby source:
# ~16.7K Canada+US localities (GeoNames cities1000 extract, CC BY 4.0,
# geonames.org) with lat/lon centroids. Radius search is a haversine scan
# over a lat-sorted window (binary-searched band, ~sub-ms), memoized per
# (city, province, radius, limit) in-process.
#
# Pure Ruby — no Rails/Discourse dependencies — so it can be unit-tested
# standalone. Privacy: operates on locality CENTROIDS only; user coordinates
# are never stored anywhere (the GPS button reverse-geocodes and discards).
module ::RrGeo
  class GeoMesh
    DATA_PATH = File.expand_path("../../data/cities_na.tsv", __dir__)
    EARTH_R_KM = 6371.0
    KM_PER_DEG_LAT = 111.0
    MEMO_MAX = 500

    COUNTRY_NAMES = { "CA" => "Canada", "US" => "United States" }.freeze

    class << self
      def available?
        File.exist?(DATA_PATH)
      rescue StandardError
        false
      end

      # rows: [[name_lc, admin1_lc, lat, lon, cc, display_name, display_admin1, primary], ...]
      # lat-sorted (the data file is written lat-sorted; we trust but verify cheaply).
      def rows
        @rows ||= begin
          out = []
          File.foreach(DATA_PATH) do |line|
            next if line.start_with?("#")
            name, admin1, lat, lon, cc, primary = line.chomp.split("\t")
            next if name.nil? || admin1.nil? || lat.nil? || lon.nil?
            out << [name.downcase, admin1.downcase, lat.to_f, lon.to_f, cc.to_s,
                    name, admin1, primary != "0"].freeze
          end
          out.sort_by! { |r| r[2] }
          out.freeze
        end
      rescue StandardError
        @rows = [].freeze
      end

      def index_by_key
        @index_by_key ||= rows.each_with_index.each_with_object({}) do |(r, i), h|
          h["#{r[0]}|#{r[1]}"] ||= i
        end
      end

      def index_by_name
        @index_by_name ||= rows.each_with_index.each_with_object({}) do |(r, i), h|
          (h[r[0]] ||= []) << i
        end
      end

      # Find a locality row. Exact city+province match first; falls back to
      # first name-only match (e.g. legacy locations missing a province).
      def find(city, province = nil)
        c = norm(city)
        return nil if c.empty?
        if (p = norm(province)) && !p.empty?
          i = index_by_key["#{c}|#{p}"]
          return rows[i] if i
        end
        ids = index_by_name[c]
        ids ? rows[ids.first] : nil
      end

      # Geofenced neighbors: localities within radius_km of the city's
      # centroid, nearest first, excluding the city itself.
      # Returns [[display_name, display_admin1, dist_km], ...]
      def neighbors(city, province = nil, radius_km: 50, limit: 12)
        radius_km = radius_km.to_f.clamp(1.0, 500.0)
        limit = limit.to_i.clamp(1, 50)
        key = "#{norm(city)}|#{norm(province)}|#{radius_km}|#{limit}"
        memo = (@memo ||= {})
        return memo[key] if memo.key?(key)
        memo.clear if memo.size >= MEMO_MAX
        memo[key] = compute_neighbors(city, province, radius_km, limit)
      end

      # Typeahead over the full mesh: prefix matches outrank substring;
      # within each bucket: exact name, then home market (CA), then shorter
      # names (closer to the query). Returns "Name, Admin1, Country".
      def search(q, limit: 8)
        ql = norm(q)
        return [] if ql.length < 2
        pre = []
        sub = []
        rows.each do |r|
          if r[0].start_with?(ql)
            pre << r
          elsif sub.length < 60 && r[0].include?(ql)
            sub << r
          end
        end
        rank = ->(r) { [r[0] == ql ? 0 : 1, r[4] == "CA" ? 0 : 1, r[0].length, r[0]] }
        (pre.sort_by(&rank) + sub.sort_by(&rank)).first(limit).map { |r| format_row(r) }
      end

      def format_row(r)
        "#{r[5]}, #{r[6]}, #{COUNTRY_NAMES[r[4]] || r[4]}"
      end

      private

      def norm(s)
        s.to_s.strip.downcase
      end

      def compute_neighbors(city, province, radius_km, limit)
        me = find(city, province)
        return [] unless me
        lat0 = me[2]
        lon0 = me[3]
        dlat = radius_km / KM_PER_DEG_LAT
        all = rows
        lo = all.bsearch_index { |r| r[2] >= lat0 - dlat } || all.length
        hits = []
        i = lo
        while i < all.length
          r = all[i]
          break if r[2] > lat0 + dlat
          # Skip: self; flagged city-sections; names that CONTAIN the anchor
          # (e.g. "Central Moncton" for Moncton) — their tokens are already
          # covered by the city level and they'd crowd out real neighbours.
          if !r.equal?(me) && !(r[0] == me[0] && r[1] == me[1]) &&
             r[7] && !r[0].include?(me[0]) && !me[0].include?(r[0])
            d = haversine_km(lat0, lon0, r[2], r[3])
            hits << [r, d] if d <= radius_km
          end
          i += 1
        end
        hits.sort_by! { |_, d| d }
        hits.first(limit).map { |r, d| [r[5], r[6], d.round(1)] }
      rescue StandardError
        []
      end

      def haversine_km(lat1, lon1, lat2, lon2)
        rad = Math::PI / 180.0
        dlat = (lat2 - lat1) * rad
        dlon = (lon2 - lon1) * rad
        a = Math.sin(dlat / 2)**2 +
            Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
        2 * EARTH_R_KM * Math.asin(Math.sqrt(a))
      end
    end
  end
end
