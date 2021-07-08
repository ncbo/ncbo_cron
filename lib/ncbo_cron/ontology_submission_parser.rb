require 'multi_json'

module NcboCron
  module Models

    class OntologySubmissionParser

      QUEUE_HOLDER = "parseQueue"
      IDPREFIX = "sub:"

      ACTIONS = {
        :process_rdf => true,
        :index_search => true,
        :index_properties => true,
        :run_metrics => true,
        :process_annotator => true,
        :diff => true
      }

      def initialize()
      end

      def queue_submission(submission, actions={:all => true})
        redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)

        if actions[:all]
          actions = ACTIONS.dup
        else
          actions.delete_if {|k, v| !ACTIONS.has_key?(k)}
        end
        actionStr = MultiJson.dump(actions)
        redis.hset(QUEUE_HOLDER, get_prefixed_id(submission.id), actionStr) unless actions.empty?
      end

      def process_queue_submissions(options = {})
        logger = options[:logger]
        logger ||= Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)
        all = queued_items(redis, logger)

        all.each do |process_data|
          actions = process_data[:actions]
          realKey = process_data[:key]
          key = process_data[:redis_key]
          redis.hdel(QUEUE_HOLDER, key)
          begin
            process_submission(logger, realKey, actions)
          rescue Exception => e
            logger.debug "Exception processing #{realKey}"
            logger.error(e.message + "\n" + e.backtrace.join("\n\t"))
          end
        end
      end

      def queued_items(redis, logger=nil)
        logger ||= Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        all = redis.hgetall(QUEUE_HOLDER)
        prefix_remove = Regexp.new(/^#{IDPREFIX}/)
        items = []
        all.each do |key, val|
          begin
            actions = MultiJson.load(val, symbolize_keys: true)
          rescue Exception => e
            logger.error("Invalid record in the parse queue: #{key} - #{val}:\n")
            logger.error(e.message + "\n" + e.backtrace.join("\n\t"))
            logger.flush()
            next
          end
          items << {
            key: key.sub(prefix_remove, ''),
            redis_key: key,
            actions: actions
          }
        end
        items
      end

      def get_prefixed_id(id)
        "#{IDPREFIX}#{id}"
      end

      # Zombie graphs are submission graphs from ontologies that have been deleted
      def zombie_classes_graphs
        query = "SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o }}"
        class_graphs = []
        Goo.sparql_query_client.query(query).each_solution do |sol|
          if sol[:g].to_s["/submissions/"] && sol[:g].to_s["/ontologies/"]
            class_graphs << sol[:g].to_s
          end
        end
        onts_set = Set.new
        onts = LinkedData::Models::Ontology.where.include(:acronym, :summaryOnly).all.each do |o|
          onts_set << o.id.to_s
        end
        zombies = []
        class_graphs.each do |g|
          zombies << g unless onts_set.include?(g.split("/")[0..-3].join("/"))
        end
        zombies
      end

      def process_flush_classes(logger, remove_zombie_graphs=false)
        onts = LinkedData::Models::Ontology.where.include(:acronym,:summaryOnly).all
        status_archived = LinkedData::Models::SubmissionStatus.find("ARCHIVED").first
        deleted = []
        onts = onts.sort_by { |x| x.acronym }
        onts.each do |ont|
          if !ont.summaryOnly
            logger.info("Checking graphs to delete for #{ont.id.to_s}")
            submissions = LinkedData::Models::OntologySubmission.where(ontology: ont)
                            .include(:submissionId)
                            .include(:submissionStatus)
                            .all
            submissions = submissions.sort_by { |x| x.submissionId }.reverse[0..10]
            last_ready = ont.latest_submission(status: :ready)
            next if last_ready.nil?
            submissions.each do |sub|
              if LinkedData::Models::Class.where.in(sub).count > 1
                if sub.archived?
                  logger.info "Deleting graph #{sub.id.to_s} ..." ; logger.flush
                  sleep(5)
                  t0 = Time.now
                  sub.delete_classes_graph
                  logger.info "Graph #{sub.id.to_s} deleted in #{Time.now-t0} sec."; logger.flush
                  deleted << sub
                else
                  if sub.id.to_s != last_ready.id.to_s
                    sub.bring_remaining
                    sleep(5)
                    logger.info "DELETE #{sub.id.to_s}"; logger.flush
                    sub.delete_classes_graph
                    logger.info "DELETE setting to archive #{sub.id.to_s}"; logger.flush
                    sub.add_submission_status(status_archived)
                    sub.save
                    logger.info "DELETE DONE"; logger.flush
                  end
                end
              end
            end
          end
        end

        zombie_classes_graphs.each do |zg|
          logger.info("Zombie class graph #{zg}"); logger.flush
          # Not deleting zombie graph by default
          if !remove_zombie_graphs.nil? && remove_zombie_graphs == true
            Goo.sparql_data_client.delete_graph(RDF::URI.new(zg))
            logger.info "DELETED #{zg} graph"
            deleted << zg
          end
        end

        logger.info("finish process_flush_classes"); logger.flush

        deleted
      end

      def process_submission(logger, submission_id, actions=ACTIONS)
        multi_logger = LinkedData::Utils::MultiLogger.new(loggers: logger)
        t0 = Time.now
        sub = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(submission_id)).first

        if sub
          sub.bring_remaining
          sub.ontology.bring(:acronym)
          FileUtils.mkdir_p(sub.data_folder) unless Dir.exists?(sub.data_folder)
          log_path = sub.parsing_log_path
          logger.info "Logging parsing output to #{log_path}"
          logger1 = Logger.new(log_path)
          multi_logger.add_logger(logger1)
          multi_logger.info "Starting to process #{submission_id}"

          # Check to make sure the file has been downloaded
          if sub.pullLocation && (!sub.uploadFilePath || !File.exist?(sub.uploadFilePath))
            multi_logger.debug "Pull location found, but no file in the upload file path. Retrying download."
            file, filename = sub.download_ontology_file
            file_location = sub.class.copy_file_repository(sub.ontology.acronym, sub.submissionId, file, filename)
            file_location = "../" + file_location if file_location.start_with?(".") # relative path fix
            sub.uploadFilePath = File.expand_path(file_location, __FILE__)
            sub.save
            multi_logger.debug "Download complete"
          end

          sub.process_submission(multi_logger, actions)
          parsed = sub.ready?(status: [:rdf, :rdf_labels])

          if parsed
            archive_old_submissions(multi_logger, sub) if actions[:process_rdf]
            process_annotator(multi_logger, sub) if actions[:process_annotator]
            multi_logger.debug "Completed processing of #{submission_id} in #{(Time.now - t0).to_f.round(2)}s"
          else
            multi_logger.error "Submission #{submission_id} parsing failed"
          end
          NcboCron::Models::OntologiesReport.new(multi_logger).refresh_report([sub.ontology.acronym])
        else
          multi_logger.error "Submission #{submission_id} is not in the system. Processing cancelled..."
        end
      end

      private

      def archive_old_submissions(logger, sub)
        # Mark older submissions archived
        logger.debug "Archiving submissions previous to #{sub.id.to_s}..."
        submissions = LinkedData::Models::OntologySubmission
                          .where(ontology: sub.ontology)
                          .include(:submissionId)
                          .include(:submissionStatus)
                          .all
        # Get recent submissions, sorted by submissionId (latest first)
        recent_submissions = submissions.sort { |a, b| b.submissionId <=> a.submissionId }[0..10]
        options = { process_rdf: false, index_search: false, index_commit: false,
                    run_metrics: false, reasoning: false, archive: true }
        recent_submissions.each do |old_sub|
          next if old_sub.id.to_s == sub.id.to_s
          next if sub.submissionId < old_sub.submissionId
          old_sub.process_submission(logger, options) unless old_sub.archived?
        end
        logger.debug "Completed archiving submissions previous to #{sub.id.to_s}"
      end

      def process_annotator(logger, sub)
        parsed = sub.ready?(status: [:rdf, :rdf_labels])

        if parsed
          begin
            annotator = Annotator::Models::NcboAnnotator.new
            annotator.create_term_cache_for_submission(logger, sub)
            annotator.generate_dictionary_file()
          rescue Exception => e
            logger.error(e.message + "\n" + e.backtrace.join("\n\t"))
            logger.flush()
          end
        else
          logger.error "Annotator entries cannot be generated on the submission #{sub.id.to_s} because it has not been successfully parsed"
        end
      end
    end

  end
end
