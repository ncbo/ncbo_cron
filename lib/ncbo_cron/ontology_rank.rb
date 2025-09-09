require 'logger'
require 'benchmark'
require_relative 'ontology_helper'

module NcboCron
  module Models

    class OntologyRank
      ONTOLOGY_RANK_REDIS_FIELD = "ontology_rank"
      BP_VISITS_NUMBER_MONTHS = 12

      def initialize(logger=nil)
        @logger = nil
        if logger.nil?
          log_file = File.new(NcboCron.settings.log_path, "a")
          log_path = File.dirname(File.absolute_path(log_file))
          log_filename_no_ext = File.basename(log_file, ".*")
          ontology_rank_log_path = File.join(log_path, "#{log_filename_no_ext}-ontology-rank.log")
          @logger = Logger.new(ontology_rank_log_path)
        else
          @logger = logger
        end
      end

      def run
        logger.info('-' * 50)
        logger.info('Starting ontology ranking process...')
        logger.flush

        time = Benchmark.realtime do
          logger.info("Connecting to Redis at " \
                       "#{NcboCron.settings.redis_host}:#{NcboCron.settings.redis_port}")
          redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)
          logger.info('Redis connection established successfully')
          logger.info('')
          logger.flush

          logger.info('Beginning ontology ranking calculation...')
          ontology_rank = rank_ontologies
          logger.info("Ranking calculation completed. Generated rankings for " \
                       "#{ontology_rank.keys.size} ontologies")
          logger.info('')

          logger.info('Storing rankings in Redis...')
          redis.set(ONTOLOGY_RANK_REDIS_FIELD, Marshal.dump(ontology_rank))
          logger.info('Rankings successfully stored in Redis')
        end

        logger.info("Finished generating ontology rankings in #{time.round(3)} seconds")
        logger.info('Process completed successfully')
        logger.flush
      end

      def rank_ontologies
        ontologies = LinkedData::Models::Ontology.where.include(:acronym, :group).to_a

        logger.info('Calculating analytics scores...')
        analytics_time = Benchmark.realtime do
          @analytics_scr = analytics_scores(ontologies)
        end
        logger.info("Analytics scores calculated in #{analytics_time.round(3)} seconds")

        logger.info('Calculating UMLS scores...')
        umls_time = Benchmark.realtime do
          @umls_scr = umls_scores(ontologies)
        end
        logger.info("UMLS scores calculated in #{umls_time.round(3)} seconds")

        logger.info('Combining scores to generate final rankings...')
        ontology_rank = {}
        @analytics_scr.each {|acronym, score| ontology_rank[acronym] = {bioportalScore: score.round(3), umlsScore: @umls_scr[acronym] ? @umls_scr[acronym].round(3) : 0.0}}

        # Log summary statistics
        bp_scores = ontology_rank.values.map { |v| v[:bioportalScore] }
        umls_scores = ontology_rank.values.map { |v| v[:umlsScore] }

        logger.info("Final rankings summary:")
        logger.info("  BioPortal scores - Min: #{bp_scores.min}, Max: #{bp_scores.max}, " \
                     "Avg: #{(bp_scores.sum / bp_scores.size).round(3)}")
        logger.info("  UMLS scores - Min: #{umls_scores.min}, Max: #{umls_scores.max}, " \
                     "Total with UMLS: #{umls_scores.count(&:positive?)}")
        logger.flush

        ontology_rank
      end

      private

      def logger
        @logger || Logger.new($stdout)
      end

      def analytics_scores(ontologies)
        visits_hash = visits_for_period(ontologies, BP_VISITS_NUMBER_MONTHS, Time.now.year, Time.now.month)

        total_visits = visits_hash.values.sum
        max_visits = visits_hash.values.max || 0
        min_visits = visits_hash.values.min || 0
        logger.info("Visit statistics:")
        logger.info("  Total visits across all ontologies: #{total_visits}")
        logger.info("  Maximum visits for single ontology: #{max_visits}")
        logger.info("  Minimum visits for single ontology: #{min_visits}")
        logger.info("  Ontologies with zero visits: #{visits_hash.values.count(0)}")

        # Find top 5 most visited ontologies
        top_ontologies = visits_hash.sort_by { |k, v| -v }.first(5)
        logger.info("Top 5 most visited ontologies:")
        top_ontologies.each_with_index do |(acronym, visits), index|
          logger.info("  #{index + 1}. #{acronym}: #{visits} visits")
        end

        # log10 normalization and range change to [0,1]
        logger.info('Applying log10 normalization...')
        if !visits_hash.values.max.nil? && visits_hash.values.max > 0
          norm_max_visits = Math.log10(visits_hash.values.max)
          logger.info("Normalization factor (log10 of max visits): #{norm_max_visits.round(3)}")
        else
          norm_max_visits = 1
          logger.info("No visits found, using normalization factor of 1")
        end

        visits_hash.each do |acr, visits|
          norm_visits = visits > 0 ? Math.log10(visits) : 0
          visits_hash[acr] = normalize(norm_visits, 0, norm_max_visits, 0, 1)
        end
        visits_hash
      end

      def umls_scores(ontologies)
        scores = {}

        ontologies.each do |ont|
          if ont.group && !ont.group.empty?
            umls_gr = ont.group.select {|gr| NcboCron::Helpers::OntologyHelper.last_fragment_of_uri(gr.id.to_s).include?('UMLS')}
            scores[ont.acronym] = umls_gr.empty? ? 0 : 1
          else
            scores[ont.acronym] = 0
          end
        end
        scores
      end

      def normalize(x, xmin, xmax, ymin, ymax)
        xrange = xmax - xmin
        yrange = ymax - ymin
        return ymin if xrange == 0
        ymin + (x - xmin) * (yrange.to_f / xrange.to_f)
      end

      # Return a hash |acronym, visits| for the last num_months. The result is ranked by visits
      def visits_for_period(ontologies, num_months, current_year, current_month)
        # Visits for all BioPortal ontologies
        acronyms = ontologies.map {|o| o.acronym }
        bp_all_visits = LinkedData::Models::Ontology.analytics(nil, nil, acronyms)
        periods = last_periods(num_months, current_year, current_month)
        period_visits = Hash.new
        bp_all_visits.each do |acronym, visits|
          period_visits[acronym] = 0
          periods.each do |p|
            year_str = p[0].to_s
            month_str = p[1].to_s
            month_visits = visits[year_str] ? visits[year_str][month_str] || 0 : 0
            period_visits[acronym] += month_visits
          end
        end
        period_visits
      end

      # Obtains an array of [year, month] elements for the last num_months
      def last_periods(num_months, year, month)
        # Array of [year, month] elements
        periods = []

        num_months.times do
          if month > 1
            month -= 1
          else
            month = 12
            year -= 1
          end
          periods << [year, month]
        end
        periods
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
# logger = Logger.new($stdout)
# NcboCron::Models::OntologyRank.new(logger).run
#
# ontology_rank_path = File.join("log", "ontology-rank.log")
# ontology_rank_logger = Logger.new(ontology_rank_path)
# NcboCron::Models::OntologyRank.new(ontology_rank_logger).run