# frozen_string_literal: true

module NcboCron
  module Models
    class CloudflareAnalytics
      def initialize(logger = nil)
        @logger = logger || Logger.new($stdout)
      end

      def run
        start_time = Time.now
        @logger.info "CloudflareAnalytics started at #{start_time.utc.iso8601}"

        json_data = load_existing_data

        yesterday = Date.today - 1 # logging yesterday's counts
        start_iso, end_iso = generate_date_range

        process_ontologies(json_data, start_iso, end_iso, yesterday.year.to_s, yesterday.month.to_s)
        write_updated_data(json_data)
        write_to_redis(json_data)

        end_time = Time.now
        duration = (end_time - start_time).round(2)
        @logger.info "CloudflareAnalytics completed at #{end_time.utc.iso8601} (duration: #{duration}s)"
      end

      # rubocop:disable Metrics/MethodLength
      def build_query(ontology_id, start_date:, end_date:)
        path = "/ontologies/#{ontology_id}"
        <<~GRAPHQL
          {
            viewer {
              budget
              zones(filter: { zoneTag: "#{NcboCron.settings.cloudflare_zone_tag}" }) {
                httpRequestsAdaptiveGroups(
                  limit: 10000,
                  filter: {
                    clientRequestPath: "#{path}",
                    datetime_geq: "#{start_date}",
                    datetime_lt: "#{end_date}"
                  },
                ) {
                  dimensions {
                    clientRequestPath
                  }
                  sum {
                    visits
                  }
                }
              }
            }
            cost
          }
        GRAPHQL
      end
      # rubocop:enable Metrics/MethodLength

      def process_ontologies(json_data, start_iso, end_iso, year_str, month_str)
        onts = LinkedData::Models::Ontology.where.include(:acronym).read_only
        ont_acronyms = onts.all.map(&:acronym).sort_by(&:downcase)
        # ont_acronyms = %w[MEDDRA NCIT SNOMEDCT]
        @logger.info "Processing #{ont_acronyms.size} ontologies..."

        ont_acronyms.each_with_index do |id, index|
          @logger.info "[#{index + 1}/#{ont_acronyms.size}] Fetching data for #{id}..."

          query = build_query(id, start_date: start_iso, end_date: end_iso)
          data = fetch_graphql(query)
          next if data.nil?

          result = extract_visits_and_budget(data)

          # Pause when budget gets low (leave buffer for safety)
          if result[:remaining_queries] && result[:remaining_queries] < 10
            @logger.warn "Budget almost depleted, waiting 5 minutes..."
            sleep(300)
          end

          update_visit_data(json_data, id, result[:visits], year_str, month_str)
          @logger.info "#{id} had #{result[:visits]} visits"
        end
      end

      def extract_visits_and_budget(data)
        unless data&.dig('data', 'viewer', 'zones')&.any?
          raise "API response missing expected zones data: #{data.inspect}"
        end

        zone = data.dig('data', 'viewer', 'zones', 0)
        unless zone&.dig('httpRequestsAdaptiveGroups')
          raise "API response missing httpRequestsAdaptiveGroups for zone: #{zone.inspect}"
        end

        visits = zone.dig('httpRequestsAdaptiveGroups', 0, 'sum', 'visits')
        budget = data.dig('data', 'viewer', 'budget')
        cost = data.dig('data', 'cost')

        if budget && cost
          remaining_queries = budget / cost
          @logger.info "Query cost: #{cost}, Budget: #{budget}, ~#{remaining_queries} queries remaining"

          if remaining_queries < 50
            @logger.warn "Budget getting low! Only ~#{remaining_queries} queries remaining"
          end
        end

        {
          visits: visits.nil? ? 0 : visits.to_i,
          budget: budget,
          cost: cost,
          remaining_queries: budget && cost ? budget / cost : nil
        }
      end

      def fetch_graphql(query)
        response = send_graphql_request(query)
        JSON.parse(response.body)
      rescue Faraday::Error => e
        @logger.error "Faraday HTTP error: #{e.class} - #{e.message}"
        nil
      rescue JSON::ParserError => e
        @logger.error "Failed to parse JSON response: #{e.class} - #{e.message}"
        nil
      end

      # UTC midnight ranges for previous day
      def generate_date_range(today = Date.today)
        end_date = today
        start_date = today - 1
        [
          start_date.strftime('%Y-%m-%dT00:00:00Z'),
          end_date.strftime('%Y-%m-%dT00:00:00Z')
        ]
      end

      def update_visit_data(json_data, ontology, count, year, month)
        json_data[ontology] ||= {}
        json_data[ontology][year] ||= {}
        json_data[ontology][year][month] ||= 0
        json_data[ontology][year][month] += count
      end

      private

      def load_existing_data
        path = NcboCron.settings.cloudflare_data_file
        abort("ERROR: File not found: #{path}") unless File.exist?(path)

        JSON.parse(File.read(path))
      end

      def write_updated_data(json_data)
        @logger.debug("Current working directory: #{Dir.pwd}")
        path = NcboCron.settings.cloudflare_data_file
        @logger.debug "Writing Cloudflare Analytics data file to #{File.expand_path(path)}"

        begin
          if File.exist?(path)
            timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
            backup_path = "#{path}.backup_#{timestamp}"

            @logger.info "Creating backup: #{backup_path}"
            FileUtils.cp(path, backup_path)
            @logger.info "Backup created successfully"
          end

          Tempfile.create('bp_cf_data') do |temp|
            temp.write(JSON.generate(json_data))
            temp.flush
            FileUtils.mv(temp.path, path)
            @logger.info "Successfully wrote #{File.size(path)} bytes to #{path}"
          end
        rescue StandardError => e
          @logger.error "File write failed: #{e.class} - #{e.message}"
          raise
        end
      end

      def write_to_redis(json_data)
        @logger.info 'Writing data to Redis...'

        begin
          redis = Redis.new(host: LinkedData.settings.ontology_analytics_redis_host,
                            port: LinkedData.settings.ontology_analytics_redis_port)
          redis.set('cloudflare_analytics', Marshal.dump(json_data))
          @logger.info 'Successfully wrote data to Redis'
        rescue Redis::BaseError => e
          @logger.error "Redis operation failed: #{e.message}"
          raise "Failed to write to Redis: #{e.message}"
        rescue StandardError => e
          @logger.error "Unexpected error writing to Redis: #{e.class} - #{e.message}"
          raise
        ensure
          redis&.close
          @logger.debug 'Redis connection closed'
        end
      end

      def cloudflare_connection
        @cloudflare_connection ||= Faraday.new(url: 'https://api.cloudflare.com') do |conn|
          conn.request :json
          conn.response :raise_error
          conn.adapter Faraday.default_adapter
        end
      end

      def send_graphql_request(query)
        cloudflare_connection.post('/client/v4/graphql') do |req|
          req.headers['Authorization'] = "Bearer #{NcboCron.settings.cloudflare_api_token}"
          req.headers['Content-Type'] = 'application/json'
          req.body = { query: query }.to_json
        end
      end
    end
  end
end

# require 'ontologies_linked_data'
# require 'goo'
# require 'ncbo_annotator'
# require 'ncbo_cron/config'
# require_relative '../../config/config'
#
# Run (output to stdout)
# NcboCron::Models::CloudflareAnalytics.new.run
#
# Run (output to log file)
# logger = Logger.new(File.join('log', 'cloudflare-analytics.log'))
# NcboCron::Models::CloudflareAnalytics.new(logger).run
#
# Run (shell command syntax example)
# ./bin/ncbo_cron \
#   --disable-processing true \
#   --disable-pull true \
#   --disable-flush true \
#   --disable-warmq true \
#   --disable-mapping-counts true \
#   --disable-ontology-analytics true \
#   --disable-ontologies-report true \
#   --disable-index-synchronizer true \
#   --disable-spam-deletion true \
#   --disable-update-check true \
#   --disable-obofoundry_sync true \
#   --cloudflare-analytics '* * * * *'
