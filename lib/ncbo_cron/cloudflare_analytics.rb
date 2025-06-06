# frozen_string_literal: true

module NcboCron
  module Models
    class CloudflareAnalytics
      def initialize
        @logger = Logger.new($stdout)
      end

      def run
        start_time = Time.now
        @logger.info "CloudflareAnalytics started at #{start_time.utc.iso8601}"

        json_data = load_existing_data

        yesterday = Date.today - 1 # logging yesterday's counts
        start_iso, end_iso = generate_date_range

        process_ontologies(json_data, start_iso, end_iso, yesterday.year.to_s, yesterday.month.to_s)
        write_updated_data(json_data)

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
          }
        GRAPHQL
      end
      # rubocop:enable Metrics/MethodLength

      def extract_visits(data)
        unless data&.dig('data', 'viewer', 'zones')&.any?
          raise "API response missing expected zones data: #{data.inspect}"
        end

        zone = data.dig('data', 'viewer', 'zones', 0)
        unless zone&.dig('httpRequestsAdaptiveGroups')
          raise "API response missing httpRequestsAdaptiveGroups for zone: #{zone.inspect}"
        end

        visits = zone.dig('httpRequestsAdaptiveGroups', 0, 'sum', 'visits')
        return 0 if visits.nil?

        visits.to_i
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
        path = NcboCron.settings.cloudflare_data_file
        Tempfile.create('bp_cf_data') do |temp|
          temp.write(JSON.generate(json_data))
          temp.flush
          FileUtils.mv(temp.path, path)
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

      def process_ontologies(json_data, start_iso, end_iso, year_str, month_str)
        onts = LinkedData::Models::Ontology.where.include(:acronym).read_only
        ont_acronyms = onts.all.map(&:acronym).sort_by(&:downcase)
        @logger.info "Processing #{ont_acronyms.size} ontologies..."

        batch_size = 250 # Requests per 5-minute window
        window_seconds = 300

        ont_acronyms.each_slice(batch_size).with_index do |batch, batch_index|
          batch_start_time = Time.now
          @logger.info "Processing batch #{batch_index + 1} (#{batch.size} ontologies)..."

          batch.each_with_index do |id, index|
            global_index = (batch_index * batch_size) + index + 1
            @logger.info "[#{global_index}/#{ont_acronyms.size}] Fetching data for #{id}..."

            query = build_query(id, start_date: start_iso, end_date: end_iso)
            data = fetch_graphql(query)
            next if data.nil?

            visits = extract_visits(data)
            update_visit_data(json_data, id, visits, year_str, month_str)
            @logger.info "#{id} had #{visits} visits"
          end

          # Wait for the full window before starting next batch
          elapsed = Time.now - batch_start_time
          if elapsed < window_seconds
            sleep_time = window_seconds - elapsed
            @logger.info "Batch complete. Waiting #{sleep_time.round(1)}s before next batch..."
            sleep(sleep_time)
          end
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
# NcboCron::Models::CloudflareAnalytics.new.run
