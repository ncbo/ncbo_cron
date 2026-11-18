require 'logger'
require 'fileutils'
require 'redis'

module NcboCron
  module Models

    # Gzips the upload files of existing UMLS submissions.
    #
    # Processing and the API download endpoints read a gzipped upload through
    # uploadFilePath (the archive) and masterFileName (the Turtle file inside it),
    # so both are pointed at the new archive. New UMLS submissions are already
    # created gzipped by bin/create_umls_submissions.rb; this brings older ones in line.
    #
    # A submission is only repointed once its archive is known to decompress to the
    # original bytes, and the original is only deleted once the triplestore holds the
    # new uploadFilePath.
    class UmlsSubmissionCompressor
      FAILED = %i[missing invalid error].freeze

      Result = Struct.new(:acronym, :submission_id, :status, :message, :size_before, :size_after,
                          keyword_init: true) do
        def failed?
          FAILED.include?(status)
        end

        def to_s
          line = "#{acronym}/#{submission_id}: #{status}"
          line += " (#{message})" if message
          line += " #{UmlsSubmissionCompressor.human_size(size_before)}" if size_before
          line += " -> #{UmlsSubmissionCompressor.human_size(size_after)}" if size_after
          line
        end
      end

      attr_reader :results

      def initialize(logger: Logger.new($stdout), dry_run: false, keep_original: false, redis: nil)
        @logger = logger
        @dry_run = dry_run
        @keep_original = keep_original
        @redis = redis
        @results = []
      end

      # acronyms limits the run to those ontologies; nil means every UMLS ontology
      def run(acronyms: nil)
        @results = []
        submissions = umls_submissions(acronyms)
        @logger.info("Found #{submissions.length} UMLS submissions#{' (dry run)' if @dry_run}")

        submissions.each do |sub|
          result = compress(sub)
          @results << result
          result.failed? ? @logger.error(result.to_s) : @logger.info(result.to_s)
        end
        @logger.info(summary)
        @results
      end

      def compress(sub)
        sub.bring(:uploadFilePath, :masterFileName, :submissionId) if sub.bring?(:uploadFilePath)
        path = sub.uploadFilePath&.to_s

        return result(sub, :no_file, 'no uploadFilePath') if path.nil? || path.empty?
        return result(sub, :missing, "#{path} not found") unless File.file?(path)
        return result(sub, :already_compressed, File.basename(path)) if sub.zipped?(path)
        return result(sub, :queued, 'queued for processing, run again once it is processed') if queued?(sub)

        size_before = File.size(path)
        return result(sub, :would_compress, path, size_before: size_before) if @dry_run

        gz_path = LinkedData::Utils::FileHelpers.gzip_file(path)
        repoint(sub, path, gz_path, size_before)
      rescue StandardError => e
        result(sub, :error, "#{e.class}: #{e.message}")
      end

      def summary
        counts = @results.group_by(&:status).transform_values(&:length)
        lines = ["UMLS submission compression summary:"]
        counts.sort_by { |status, _| status.to_s }.each { |status, n| lines << "  #{status}: #{n}" }

        compressed = @results.select { |r| r.status == :compressed }
        unless compressed.empty?
          before = compressed.sum(&:size_before)
          after = compressed.sum(&:size_after)
          lines << "  space freed: #{self.class.human_size(before - after)} " \
                   "(#{self.class.human_size(before)} -> #{self.class.human_size(after)})"
        end

        pending = @results.select { |r| r.status == :would_compress }
        lines << "  to compress: #{self.class.human_size(pending.sum(&:size_before))}" unless pending.empty?
        lines.join("\n")
      end

      def failures
        @results.select(&:failed?)
      end

      def self.human_size(bytes)
        units = %w[B KB MB GB TB]
        size = bytes.to_f
        unit = 0
        while size >= 1024 && unit < units.length - 1
          size /= 1024
          unit += 1
        end
        format(unit.zero? ? '%d %s' : '%.1f %s', size, units[unit])
      end

      private

      def repoint(sub, path, gz_path, size_before)
        sub.bring_remaining
        old_master = sub.masterFileName
        sub.uploadFilePath = gz_path
        sub.masterFileName = LinkedData::Utils::FileHelpers.filenames_in_archive(gz_path).first

        unless sub.valid?
          sub.uploadFilePath = path
          sub.masterFileName = old_master
          FileUtils.rm_f(gz_path)
          return result(sub, :invalid, "not saved: #{sub.errors.inspect}")
        end

        begin
          sub.save
        rescue StandardError
          # The store may hold either path now, or neither if the save failed between
          # its delete and its insert. Keep both files unless it still holds the original.
          FileUtils.rm_f(gz_path) if stored_upload_path(sub) == path
          raise
        end

        stored = stored_upload_path(sub)
        unless stored == gz_path
          return result(sub, :error, "uploadFilePath reads back as #{stored.inspect} after saving; " \
                                     "kept #{path} and #{gz_path}")
        end

        FileUtils.rm_f(path) unless @keep_original
        result(sub, :compressed, File.basename(gz_path), size_before: size_before, size_after: File.size(gz_path))
      end

      def umls_submissions(acronyms)
        umls = LinkedData::Models::OntologyFormat.find('UMLS').first
        raise ArgumentError, 'The UMLS ontology format is not in the triplestore' if umls.nil?

        subs = LinkedData::Models::OntologySubmission.where(hasOntologyLanguage: umls)
                                                     .include(:submissionId, :uploadFilePath, :masterFileName,
                                                              ontology: [:acronym])
                                                     .all
        if acronyms
          wanted = acronyms.map(&:upcase)
          subs = subs.select { |s| wanted.include?(s.ontology.acronym.upcase) }
          found = subs.map { |s| s.ontology.acronym.upcase }.uniq
          (wanted - found).each { |acr| @logger.warn("#{acr}: no UMLS submissions found") }
        end
        subs.sort_by { |s| [s.ontology.acronym, s.submissionId] }
      end

      def queued?(sub)
        redis.hexists(NcboCron::Helpers::OntologyHelper::PROCESS_QUEUE_HOLDER,
                      NcboCron::Helpers::OntologyHelper.get_prefixed_id(sub.id))
      end

      def redis
        @redis ||= Redis.new(host: NcboCron.settings.redis_host, port: NcboCron.settings.redis_port)
      end

      def stored_upload_path(sub)
        stored = LinkedData::Models::OntologySubmission.find(sub.id).include(:uploadFilePath).first
        stored&.uploadFilePath&.to_s
      end

      def result(sub, status, message = nil, size_before: nil, size_after: nil)
        Result.new(acronym: sub.ontology.acronym, submission_id: sub.submissionId, status: status,
                   message: message, size_before: size_before, size_after: size_after)
      end
    end
  end
end
