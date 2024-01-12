require 'logger'
require_relative 'ontology_helper'

module NcboCron
  module Models

    class OntologyPull

      def do_remote_ontology_pull(options = {})
        logger = options[:logger] || Logger.new($stdout)
        logger.info "UMLS auto-pull #{options[:enable_pull_umls] == true}"
        logger.flush
        ontologies = LinkedData::Models::Ontology.where.include(:acronym).all
        ont_to_include = []
        # ont_to_include = ["GVP"]
        ontologies.select! { |ont| ont_to_include.include?(ont.acronym) } unless ont_to_include.empty?
        enable_pull_umls = options[:enable_pull_umls]
        umls_download_url = options[:pull_umls_url]
        ontologies.sort! { |a, b| a.acronym.downcase <=> b.acronym.downcase }
        new_submissions = []

        ontologies.each do |ont|
          begin
            begin
              new_submissions << NcboCron::Helpers::OntologyHelper.do_ontology_pull(ont.acronym,
                                                       enable_pull_umls: enable_pull_umls,
                                                       umls_download_url: umls_download_url,
                                                       logger: logger, add_to_queue: true)
            rescue NcboCron::Helpers::OntologyHelper::RemoteFileException => error
              logger.info "RemoteFileException: No submission file at pull location #{error.submission.pullLocation.to_s} for ontology #{ont.acronym}."
              logger.flush
              LinkedData::Utils::Notifications.remote_ontology_pull(error.submission)
            end
          end
        rescue Exception => e
          logger.error "Problem retrieving #{ont.acronym} in OntologyPull:\n" + e.message + "\n" + e.backtrace.join("\n\t")
          logger.flush()
          next
        end

        if options[:cache_clear] == true
          logger.info('Clearing Goo/HTTP caches...')
          redis_goo.flushdb
          redis_http.flushdb
          logger.info('Completed clearing Goo/HTTP caches')
        end
        new_submissions
      end

      private

      def redis_goo
        Redis.new(host: LinkedData.settings.goo_redis_host, port: LinkedData.settings.goo_redis_port, timeout: 30)
      end

      def redis_http
        Redis.new(host: LinkedData.settings.http_redis_host, port: LinkedData.settings.http_redis_port, timeout: 30)
      end
    end
  end
end

# require 'ontologies_linked_data'
# require 'goo'
# require 'ncbo_annotator'
# require 'ncbo_cron/config'
# require_relative '../../config/config'
# ontologies_pull_log_path = File.join("logs", "scheduler-pull.log")
# ontologies_pull_logger = Logger.new(ontologies_pull_log_path)
# pull = NcboCron::Models::OntologyPull.new
# pull.do_remote_ontology_pull({logger: ontologies_pull_logger, enable_pull_umls: false})
# ./bin/ncbo_cron --disable-processing true --disable-flush true --disable-warmq true --disable-ontology-analytics true --disable-ontologies-report true --disable-mapping-counts true --disable-spam-deletion true --pull-cron '22 * * * *'
