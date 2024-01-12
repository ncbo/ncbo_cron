require 'logger'

module NcboCron
  module Helpers
    module OntologyHelper

      REDIS_SUBMISSION_ID_PREFIX = "sub:"
      PROCESS_QUEUE_HOLDER = "parseQueue"
      PROCESS_ACTIONS = {
        :process_rdf => true,
        :generate_labels => true,
        :index_search => true,
        :index_properties => true,
        :run_metrics => true,
        :process_annotator => true,
        :diff => true,
        :remote_pull => false
      }

      class RemoteFileException < StandardError
        attr_reader :submission

        def initialize(submission)
          super
          @submission = submission
        end
      end

      def self.do_ontology_pull(ontology_acronym, enable_pull_umls = false, umls_download_url = '', logger = nil,
                                add_to_queue = true)
        logger ||= Logger.new($stdout)
        ont = LinkedData::Models::Ontology.find(ontology_acronym).include(:acronym).first
        new_submission = nil
        raise StandardError, "Ontology #{ontology_acronym} not found" if ont.nil?

        last = ont.latest_submission(status: :any)
        raise StandardError, "No submission found for #{ontology_acronym}" if last.nil?

        last.bring(:hasOntologyLanguage) if last.bring?(:hasOntologyLanguage)
        if !enable_pull_umls && last.hasOntologyLanguage.umls?
          raise StandardError, "Pull umls not enabled"
        end

        last.bring(:pullLocation) if last.bring?(:pullLocation)
        raise StandardError, "#{ontology_acronym} has no pullLocation" if last.pullLocation.nil?

        last.bring(:uploadFilePath) if last.bring?(:uploadFilePath)

        if last.hasOntologyLanguage.umls? && umls_download_url && !umls_download_url.empty?
          last.pullLocation = RDF::URI.new(umls_download_url + last.pullLocation.split("/")[-1])
          logger.info("Using alternative download for umls #{last.pullLocation.to_s}")
          logger.flush
        end

        if last.remote_file_exists?(last.pullLocation.to_s)
          logger.info "Checking download for #{ont.acronym}"
          logger.info "Location: #{last.pullLocation.to_s}"; logger.flush
          file, filename = last.download_ontology_file
          file, md5local, md5remote, new_file_exists = self.new_file_exists?(file, last)

          if new_file_exists
            logger.info "New file found for #{ont.acronym}\nold: #{md5local}\nnew: #{md5remote}"
            logger.flush()
            new_submission = self.create_submission(ont, last, file, filename, logger, add_to_queue)
          else
            logger.info "There is no new file found for #{ont.acronym}"
            logger.flush()
          end

          file.close
          new_submission
        else
          raise self::RemoteFileException.new(last)
        end
      end

      def self.create_submission(ont, sub, file, filename, logger = nil, add_to_queue = true, new_version = nil,
                                 new_released = nil)
        logger ||= Kernel.const_defined?("LOGGER") ? Kernel.const_get("LOGGER") : Logger.new(STDOUT)
        new_sub = LinkedData::Models::OntologySubmission.new

        sub.bring_remaining
        sub.loaded_attributes.each do |attr|
          new_sub.send("#{attr}=", sub.send(attr))
        end

        submission_id = ont.next_submission_id()
        new_sub.submissionId = submission_id
        file_location = LinkedData::Models::OntologySubmission.copy_file_repository(ont.acronym, submission_id, file, filename)
        new_sub.uploadFilePath = file_location

        unless new_version.nil?
          new_sub.version = new_version
        end

        if new_released.nil?
          new_sub.released = DateTime.now
        else
          new_sub.released = DateTime.parse(new_released)
        end
        new_sub.submissionStatus = nil
        new_sub.creationDate = nil
        new_sub.missingImports = nil
        new_sub.metrics = nil
        full_file_path = File.expand_path(file_location)

        # check if OWLAPI is able to parse the file before creating a new submission
        owlapi = LinkedData::Parser::OWLAPICommand.new(
          full_file_path,
          File.expand_path(new_sub.data_folder.to_s),
          logger: logger)
        owlapi.disable_reasoner
        parsable = true

        begin
          owlapi.parse
        rescue Exception => e
          logger.error("The new file for ontology #{ont.acronym}, submission id: #{submission_id} did not clear OWLAPI: #{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}")
          logger.error("A new submission has NOT been created.")
          logger.flush
          parsable = false
        end

        if parsable
          if new_sub.valid?
            new_sub.save()

            if add_to_queue
              self.queue_submission(new_sub, { all: true })
              logger.info("OntologyPull created a new submission (#{submission_id}) for ontology #{ont.acronym}")
            end
          else
            logger.error("Unable to create a new submission for ontology #{ont.acronym} with id #{submission_id}: #{new_sub.errors}")
            logger.flush
          end
        else
          # delete the bad file
          File.delete full_file_path if File.exist? full_file_path
        end
        new_sub
      end

      def self.queue_submission(submission, actions={:all => true})
        redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)

        if actions[:all]
          actions = PROCESS_ACTIONS.dup
        else
          actions.delete_if {|k, v| !PROCESS_ACTIONS.has_key?(k)}
        end
        actionStr = MultiJson.dump(actions)
        redis.hset(PROCESS_QUEUE_HOLDER, get_prefixed_id(submission.id), actionStr) unless actions.empty?
      end

      def self.get_prefixed_id(id)
        "#{REDIS_SUBMISSION_ID_PREFIX}#{id}"
      end

      def self.last_fragment_of_uri(uri)
        uri.to_s.split("/")[-1]
      end

      def self.acronym_from_submission_id(submissionID)
        submissionID.to_s.split("/")[-3]
      end

      def self.new_file_exists?(file, last)
        file = File.open(file.path, "rb")
        remote_contents = file.read
        md5remote = Digest::MD5.hexdigest(remote_contents)

        if last.uploadFilePath && File.exist?(last.uploadFilePath)
          file_contents = open(last.uploadFilePath) { |f| f.read }
          md5local = Digest::MD5.hexdigest(file_contents)
          new_file_exists = (not md5remote.eql?(md5local))
        else
          # There is no existing file, so let's create a submission with the downloaded one
          new_file_exists = true
        end
        return file, md5local, md5remote, new_file_exists
      end

    end
  end
end