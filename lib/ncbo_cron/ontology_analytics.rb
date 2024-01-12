require 'logger'
require 'json'
require 'benchmark'
require 'google/analytics/data'


module NcboCron
  module Models

    class OntologyAnalytics
      ONTOLOGY_ANALYTICS_REDIS_FIELD = 'ontology_analytics'
      UA_START_DATE = '2013-10-01'
      GA4_START_DATE = '2023-06-01'

      def initialize(logger)
        @logger = logger
      end

      def run
        redis = Redis.new(:host => LinkedData.settings.ontology_analytics_redis_host, :port => LinkedData.settings.ontology_analytics_redis_port)
        ontology_analytics = fetch_ontology_analytics
        File.open(NcboCron.settings.analytics_path_to_ga_data_file, 'w') do |f|
          f.write(ontology_analytics.to_json)
        end
        redis.set(ONTOLOGY_ANALYTICS_REDIS_FIELD, Marshal.dump(ontology_analytics))
      end

      def fetch_ontology_analytics
        @logger.info "Starting Google Analytics refresh..."
        @logger.flush
        full_data = nil

        time = Benchmark.realtime do
          max_results = 10000
          aggregated_results = Hash.new

          @logger.info "Fetching all ontology acronyms from backend..."
          @logger.flush
          ont_acronyms = LinkedData::Models::Ontology.where.include(:acronym).all.map {|o| o.acronym}
          # ont_acronyms = ["NCIT", "SNOMEDCT", "MEDDRA"]
          @logger.info "Authenticating with the Google Analytics Endpoint..."
          @logger.flush
          google_client = authenticate_google

          date_range = Google::Analytics::Data::V1beta::DateRange.new(
            start_date: GA4_START_DATE,
            end_date: Date.today.to_s
          )
          metrics_page_views = Google::Analytics::Data::V1beta::Metric.new(
            name: "screenPageViews"
          )
          dimension_path = Google::Analytics::Data::V1beta::Dimension.new(
            name: "pagePath"
          )
          dimension_year = Google::Analytics::Data::V1beta::Dimension.new(
            name: "year"
          )
          dimension_month = Google::Analytics::Data::V1beta::Dimension.new(
            name: "month"
          )
          string_filter = Google::Analytics::Data::V1beta::Filter::StringFilter.new(
            match_type: Google::Analytics::Data::V1beta::Filter::StringFilter::MatchType::FULL_REGEXP
          )
          filter = Google::Analytics::Data::V1beta::Filter.new(
            field_name: "pagePath",
            string_filter: string_filter
          )
          filter_expression = Google::Analytics::Data::V1beta::FilterExpression.new(
            filter: filter
          )
          order_year = Google::Analytics::Data::V1beta::OrderBy::DimensionOrderBy.new(
            dimension_name: "year"
          )
          orderby_year = Google::Analytics::Data::V1beta::OrderBy.new(
            desc: false,
            dimension: order_year
          )
          order_month = Google::Analytics::Data::V1beta::OrderBy::DimensionOrderBy.new(
            dimension_name: "month"
          )
          orderby_month = Google::Analytics::Data::V1beta::OrderBy.new(
            desc: false,
            dimension: order_month
          )
          @logger.info "Fetching GA4 analytics for all ontologies..."
          @logger.flush

          ont_acronyms.each do |acronym|
            start_index = 0
            string_filter.value = "^(\\/ontologies\\/#{acronym})(\\/?\\?{0}|\\/?\\?{1}.*)$"

            loop do
              request = Google::Analytics::Data::V1beta::RunReportRequest.new(
                property: "properties/#{NcboCron.settings.analytics_property_id}",
                metrics: [metrics_page_views],
                dimension_filter: filter_expression,
                dimensions: [dimension_path, dimension_year, dimension_month],
                date_ranges: [date_range],
                order_bys: [orderby_year, orderby_month],
                offset: start_index,
                limit: max_results
              )
              response = google_client.run_report request

              response.rows ||= []
              start_index += max_results
              num_results = response.rows.length
              @logger.info "Acronym: #{acronym}, Results: #{num_results}, Start Index: #{start_index}"
              @logger.flush

              response.rows.each do |row|
                row_h = row.to_h
                year_month_hits =  row_h[:dimension_values].map.with_index {
                  |v, i| i > 0 ? v[:value].to_i.to_s : row_h[:metric_values][0][:value].to_i
                }.rotate(1)

                if aggregated_results.has_key?(acronym)
                  # year
                  if aggregated_results[acronym].has_key?(year_month_hits[0])
                    # month
                    if aggregated_results[acronym][year_month_hits[0]].has_key?(year_month_hits[1])
                      aggregated_results[acronym][year_month_hits[0]][year_month_hits[1]] += year_month_hits[2]
                    else
                      aggregated_results[acronym][year_month_hits[0]][year_month_hits[1]] = year_month_hits[2]
                    end
                  else
                    aggregated_results[acronym][year_month_hits[0]] = Hash.new
                    aggregated_results[acronym][year_month_hits[0]][year_month_hits[1]] = year_month_hits[2]
                  end
                else
                  aggregated_results[acronym] = Hash.new
                  aggregated_results[acronym][year_month_hits[0]] = Hash.new
                  aggregated_results[acronym][year_month_hits[0]][year_month_hits[1]] = year_month_hits[2]
                end
              end
              break if num_results < max_results
            end # loop
          end # ont_acronyms
          @logger.info "Refresh complete"
          @logger.flush
          full_data = merge_and_fill_missing_data(aggregated_results)
        end # Benchmark.realtime
        @logger.info "Completed Google Analytics refresh in #{(time/60).round(1)} minutes."
        @logger.flush
        full_data
      end

      def merge_and_fill_missing_data(ga4_data)
        ua_data = {}

        if File.exists?(NcboCron.settings.analytics_path_to_ua_data_file) &&
            !File.zero?(NcboCron.settings.analytics_path_to_ua_data_file)
          @logger.info "Merging GA4 and UA data..."
          @logger.flush
          ua_data_file = File.read(NcboCron.settings.analytics_path_to_ua_data_file)
          ua_data = JSON.parse(ua_data_file)
          ua_ga4_intersecting_year = Date.parse(GA4_START_DATE).year.to_s
          ua_ga4_intersecting_month = Date.parse(GA4_START_DATE).month.to_s

          # add up hits for June of 2023 (the only intersecting month between UA and GA4)
          ua_data.each do |acronym, _|
            if ga4_data.has_key?(acronym)
              if ga4_data[acronym][ua_ga4_intersecting_year].has_key?(ua_ga4_intersecting_month)
                ua_data[acronym][ua_ga4_intersecting_year][ua_ga4_intersecting_month] +=
                    ga4_data[acronym][ua_ga4_intersecting_year][ua_ga4_intersecting_month]
                # delete data for June of 2023 from ga4_data to avoid overwriting when merging
                ga4_data[acronym][ua_ga4_intersecting_year].delete(ua_ga4_intersecting_month)
              end
            end
          end
        end

        # merge ua and ga4 data
        merged_data = ua_data.deep_merge(ga4_data)
        # fill missing years and months
        @logger.info "Filling in missing years data..."
        @logger.flush
        fill_missing_data(merged_data)
        # sort acronyms, years and months
        @logger.info "Sorting final data..."
        @logger.flush
        sort_ga_data(merged_data)
      end

      def fill_missing_data(ga_data)
        # fill up non existent years
        start_year = Date.parse(UA_START_DATE).year

        ga_data.each do |acronym, _|
          (start_year..Date.today.year).each do |y|
            ga_data[acronym] = Hash.new if ga_data[acronym].nil?
            ga_data[acronym][y.to_s] = Hash.new unless ga_data[acronym].has_key?(y.to_s)
          end
          # fill up non existent months with zeros
          (1..12).each { |n| ga_data[acronym].values.each { |v| v[n.to_s] = 0 unless v.has_key?(n.to_s) } }
        end
      end

      def sort_ga_data(ga_data)
        ga_data.transform_values { |value|
          value.transform_values { |val|
            val.sort_by { |key, _| key.to_i }.to_h
          }.sort_by { |k, _| k.to_i }.to_h
        }.sort.to_h
      end

      def authenticate_google
        Google::Analytics::Data.analytics_data do |config|
          config.credentials = NcboCron.settings.analytics_path_to_key_file
        end
      end
    end # class

  end
end

class ::Hash
  def deep_merge(second)
    merger = proc { |key, v1, v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
    self.merge(second, &merger)
  end
end

# require 'ontologies_linked_data'
# require 'goo'
# require 'ncbo_annotator'
# require 'ncbo_cron/config'
# require_relative '../../config/config'
# # ontology_analytics_log_path = File.join("logs", "ontology-analytics.log")
# # ontology_analytics_logger = Logger.new(ontology_analytics_log_path)
# ontology_analytics_logger = Logger.new(STDOUT)
# NcboCron::Models::OntologyAnalytics.new(ontology_analytics_logger).run
# ./bin/ncbo_cron --disable-processing true --disable-pull true --disable-flush true --disable-warmq true --disable-ontologies-report true --disable-mapping-counts true --disable-spam-deletion true --ontology-analytics '14 * * * *'
