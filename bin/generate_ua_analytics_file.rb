require 'logger'
require 'google/apis/analytics_v3'
require 'google/api_client/auth/key_utils'

module NcboCron
  module Models

    class OntologyAnalyticsUA

      def initialize(logger)
        @logger = logger
      end

      def run
        redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)
        ontology_analytics = fetch_ontology_analytics
        File.open(NcboCron.settings.analytics_path_to_ua_data_file, 'w') do |f|
          f.write(ontology_analytics.to_json)
        end
      end

      def fetch_ontology_analytics
        google_client = authenticate_google
        aggregated_results = Hash.new
        start_year = Date.parse(NcboCron.settings.analytics_start_date).year || 2013
        ont_acronyms = LinkedData::Models::Ontology.where.include(:acronym).all.map {|o| o.acronym}
        # ont_acronyms = ["NCIT", "ONTOMA", "CMPO", "AEO", "SNOMEDCT"]
        filter_str = (NcboCron.settings.analytics_filter_str.nil? || NcboCron.settings.analytics_filter_str.empty?) ? "" : ";#{NcboCron.settings.analytics_filter_str}"

        ont_acronyms.each do |acronym|
          max_results = 10000
          num_results = 10000
          start_index = 1
          results = nil

          loop do
            results = google_client.get_ga_data(
              ids          = NcboCron.settings.analytics_profile_id,
              start_date   = NcboCron.settings.analytics_start_date,
              end_date     = Date.today.to_s,
              metrics      = 'ga:pageviews',
              {
                dimensions:  'ga:pagePath,ga:year,ga:month',
                filters:     "ga:pagePath=~^(\\/ontologies\\/#{acronym})(\\/?\\?{0}|\\/?\\?{1}.*)$#{filter_str}",
                start_index: start_index,
                max_results: max_results
              }
            )
            results.rows ||= []
            start_index += max_results
            num_results = results.rows.length
            @logger.info "Acronym: #{acronym}, Results: #{num_results}, Start Index: #{start_index}"
            @logger.flush

            results.rows.each do |row|
              if aggregated_results.has_key?(acronym)
                # year
                if aggregated_results[acronym].has_key?(row[1].to_i)
                  # month
                  if aggregated_results[acronym][row[1].to_i].has_key?(row[2].to_i)
                    aggregated_results[acronym][row[1].to_i][row[2].to_i] += row[3].to_i
                  else
                    aggregated_results[acronym][row[1].to_i][row[2].to_i] = row[3].to_i
                  end
                else
                  aggregated_results[acronym][row[1].to_i] = Hash.new
                  aggregated_results[acronym][row[1].to_i][row[2].to_i] = row[3].to_i
                end
              else
                aggregated_results[acronym] = Hash.new
                aggregated_results[acronym][row[1].to_i] = Hash.new
                aggregated_results[acronym][row[1].to_i][row[2].to_i] = row[3].to_i
              end
            end

            if num_results < max_results
              # fill up non existent years
              (start_year..Date.today.year).each do |y|
                aggregated_results[acronym] = Hash.new if aggregated_results[acronym].nil?
                aggregated_results[acronym][y] = Hash.new unless aggregated_results[acronym].has_key?(y)
              end
              # fill up non existent months with zeros
              (1..12).each { |n| aggregated_results[acronym].values.each { |v| v[n] = 0 unless v.has_key?(n) } }
              break
            end
          end
        end

        @logger.info "Completed Universal Analytics pull..."
        @logger.flush

        aggregated_results
      end

      def authenticate_google
        Google::Apis::ClientOptions.default.application_name = NcboCron.settings.analytics_app_name
        Google::Apis::ClientOptions.default.application_version = NcboCron.settings.analytics_app_version
        # enable google api call retries in order to
        # minigate analytics processing failure due to occasional google api timeouts and other outages
        Google::Apis::RequestOptions.default.retries = 5
        # uncoment to enable logging for debugging purposes
        # Google::Apis.logger.level = Logger::DEBUG
        # Google::Apis.logger = @logger
        client = Google::Apis::AnalyticsV3::AnalyticsService.new
        key = Google::APIClient::KeyUtils::load_from_pkcs12(NcboCron.settings.analytics_path_to_ua_key_file, 'notasecret')
        client.authorization = Signet::OAuth2::Client.new(
          :token_credential_uri => 'https://accounts.google.com/o/oauth2/token',
          :audience             => 'https://accounts.google.com/o/oauth2/token',
          :scope                => 'https://www.googleapis.com/auth/analytics.readonly',
          :issuer               => NcboCron.settings.analytics_service_account_email_address,
          :signing_key          => key
        ).tap { |auth| auth.fetch_access_token! }
        client
      end
    end
  end
end

require 'ontologies_linked_data'
require 'goo'
require 'ncbo_annotator'
require 'ncbo_cron/config'
require_relative '../config/config'
ontology_analytics_log_path = File.join("logs", "ontology-analytics-ua.log")
ontology_analytics_logger = Logger.new(ontology_analytics_log_path)
NcboCron::Models::OntologyAnalyticsUA.new(ontology_analytics_logger).run
