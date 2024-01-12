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
        @logger.info("Generating ontology rankings..."); @logger.flush
        @logger.flush

        time = Benchmark.realtime do
          redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)
          ontology_rank = rank_ontologies
          redis.set(ONTOLOGY_RANK_REDIS_FIELD, Marshal.dump(ontology_rank))
        end
        @logger.info("Finished generating ontology rankings in #{time} sec."); @logger.flush
      end

      def rank_ontologies
        ontology_rank = {}
        ontologies = LinkedData::Models::Ontology.where.include(:acronym, :group).to_a
        analytics_scr = analytics_scores(ontologies)
        umls_scr = umls_scores(ontologies)
        analytics_scr.each {|acronym, score| ontology_rank[acronym] = {bioportalScore: score.round(3), umlsScore: umls_scr[acronym] ? umls_scr[acronym].round(3) : 0.0}}
        ontology_rank
      end

      private

      def analytics_scores(ontologies)
        visits_hash = visits_for_period(ontologies, BP_VISITS_NUMBER_MONTHS, Time.now.year, Time.now.month)

        # log10 normalization and range change to [0,1]
        if !visits_hash.values.max.nil? && visits_hash.values.max > 0
          norm_max_visits = Math.log10(visits_hash.values.max)
        else
          norm_max_visits = 1
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
            period_visits[acronym] += visits[p[0]] ? visits[p[0]][p[1]] || 0 : 0
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
# ontology_rank_path = File.join("logs", "ontology-rank.log")
# ontology_rank_logger = Logger.new(ontology_rank_path)
# NcboCron::Models::OntologyRank.new(ontology_rank_logger).run