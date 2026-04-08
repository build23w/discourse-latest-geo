# frozen_string_literal: true
# name: discourse-latest-geo
# about: GEO prioritization if the user has not set it already + session IP exposure
# version: 0.2.4
# authors: build23w

enabled_site_setting :rr_geo_enabled

register_asset "stylesheets/common/rr-geo-feed-label.scss"

after_initialize do
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
      def latest_results(options = {})
        rel = super
        return rel unless SiteSetting.rr_geo_enabled
        return rel if options[:order].present?

        user = @guardian&.user
        return rel unless user

        location = user.user_profile&.location
        tokens = ::RrGeo::Util.tokens_from_location(location)
        return rel if tokens.blank?

        patterns = tokens.map { |t| "%#{ActiveRecord::Base.sanitize_sql_like(t)}%" }
        q_array = ::RrGeo::Util.quote_patterns(patterns)

        rel
          .joins(<<~SQL)
            LEFT JOIN topic_tags tt ON tt.topic_id = topics.id
            LEFT JOIN tags tg ON tg.id = tt.tag_id
            LEFT JOIN categories c ON c.id = topics.category_id
          SQL
          .select(<<~SQL)
            topics.*,
            CASE
              WHEN topics.title ILIKE ANY (ARRAY[#{q_array}])
                OR tg.name      ILIKE ANY (ARRAY[#{q_array}])
                OR c.name       ILIKE ANY (ARRAY[#{q_array}])
              THEN 0 ELSE 1
            END AS rr_geo_rank
          SQL
          .distinct(true)
          .reorder(Arel.sql("rr_geo_rank ASC, topics.bumped_at DESC"))
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
