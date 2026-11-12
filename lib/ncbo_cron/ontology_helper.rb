require 'logger'

module NcboCron
  module Helpers
    module OntologyHelper

      REDIS_SUBMISSION_ID_PREFIX = "sub:"
      PROCESS_QUEUE_HOLDER = "parseQueue"
      PROCESS_ACTIONS = {
        :process_rdf => true,
        :generate_labels => true,
        :extract_metadata => true,
        :index_all_data => false,
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
          @submission = submission
          location = submission.pullLocation || "unspecified location"
          super("RemoteFileException: No remote file found for submission #{submission.id} at #{location}")
        end
      end

      class MissingPullLocationException < StandardError
        attr_reader :acronym

        def initialize(acronym)
          super("MissingPullLocationException: Ontology #{acronym} has no pullLocation")
          @acronym = acronym
        end
      end

      class NoSubmissionException < StandardError
        attr_reader :acronym

        def initialize(acronym)
          @acronym = acronym
          super("NoSubmissionEception: No submission found for ontology #{acronym}")
        end
      end

      def self.do_ontology_pull(ontology_acronym,
                                logger: nil,
                                add_to_queue: true)
        logger ||= Logger.new($stdout)
        ont = LinkedData::Models::Ontology.find(ontology_acronym).include(:acronym).first
        new_submission = nil
        raise StandardError, "Ontology #{ontology_acronym} not found" if ont.nil?

        last = ont.latest_submission(status: :any)
        raise NoSubmissionException.new(ontology_acronym) if last.nil?

        last.bring(:hasOntologyLanguage) if last.bring?(:hasOntologyLanguage)

        last.bring(:pullLocation) if last.bring?(:pullLocation)
        raise MissingPullLocationException.new(ontology_acronym) if last.pullLocation.nil?

        last.bring(:uploadFilePath) if last.bring?(:uploadFilePath)

        raise self::RemoteFileException.new(last) unless last.remote_file_exists?(last.pullLocation.to_s)
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
        new_sub.masterFileName = nil
        new_sub.metrics = nil
        full_file_path = File.expand_path(file_location)

        # check if OWLAPI is able to parse the file before creating a new submission
        parsable = begin
          set_single_entry_master_file(new_sub, full_file_path)
          owlapi_checked_in_rdf_step?(new_sub) || new_sub.parsable?(logger: logger)
        rescue StandardError => e
          # e.g. a corrupt archive, which fails while being unpacked rather than in OWLAPI
          logger.error("The new file for ontology #{ont.acronym}, submission id: #{submission_id} could not be checked: #{e.class}: #{e.message}")
          false
        end

        if parsable
          if new_sub.valid?
            new_sub.save

            if add_to_queue
              queue_submission(new_sub, { all: true })
              logger.info("OntologyPull created a new submission (#{submission_id}) for ontology #{ont.acronym}")
            end
            return new_sub
          end
          logger.error("Unable to create a new submission for ontology #{ont.acronym} with id #{submission_id}: #{new_sub.errors}")
        else
          # parsable? rescues the OWLAPI exception itself, so only the outcome is available here
          logger.error("The new file for ontology #{ont.acronym}, submission id: #{submission_id} did not clear OWLAPI")
        end

        logger.error("A new submission has NOT been created.")
        # Nothing was saved, so this submission's folder holds only what this attempt wrote:
        # the downloaded file, unzipped/ and OWLAPI output.
        FileUtils.rm_rf(File.dirname(full_file_path)) unless new_sub.persistent?
        logger.flush
        nil
      end

      # parsable? unpacks archives through unzip_submission, which saves the submission when it
      # auto-sets masterFileName for a single-entry archive. Setting it here first keeps the
      # parse check from persisting anything. Multi-entry archives are left as they were.
      def self.set_single_entry_master_file(submission, file_path)
        return unless submission.zipped?(file_path)

        entries = LinkedData::Utils::FileHelpers.filenames_in_archive(file_path)
        submission.masterFileName = entries.first if entries.length == 1
      end

      # With umls_owlapi_parse on, the RDF step runs OWLAPI on UMLS submissions
      # and fails on a file it cannot parse, so a parse here would only repeat
      # it. Off, this parse is what writes the metrics.csv holding the max depth.
      def self.owlapi_checked_in_rdf_step?(submission)
        return false unless LinkedData.settings.umls_owlapi_parse

        format = submission.hasOntologyLanguage
        !format.nil? && format.umls?
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
        # Keep the original Tempfile reference alive so it isn't GC'd/unlinked.
        remote_contents = File.binread(file.path)
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
