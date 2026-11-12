require 'logger'

# A Logger that also keeps every ERROR and FATAL message it is given.
#
# Submission processing catches failures and logs them so the cron daemon can
# move on to the next queue item: OntologySubmissionParser#process_queue_submissions
# and #process_annotator rescue Exception, OntologyPull#do_remote_ontology_pull
# rescues StandardError, and many ontologies_linked_data steps log and carry on.
# A test that only checks side effects passes even when one of these fires, so
# tests pass this logger in and check its errors afterwards.
class ErrorRecordingLogger < Logger
  attr_reader :errors

  def initialize(io = $stdout)
    super(io)
    @errors = []
  end

  def add(severity, message = nil, progname = nil)
    severity ||= UNKNOWN
    # Resolve the message here, as Logger#add would, so a block runs only once
    if message.nil?
      if block_given?
        message = yield
      else
        message = progname
        progname = nil
      end
    end
    @errors << self.class.message_text(message) if severity >= ERROR
    super(severity, message, progname)
  end

  # LinkedData::Utils::MultiLogger passes its arguments on as an array, and a
  # MultiLogger wrapping another nests them, so flatten to plain text
  def self.message_text(message)
    case message
    when Array then message.map { |m| message_text(m) }.join(' ')
    when Exception then "#{message.message} (#{message.class})"
    else message.to_s
    end
  end
end

module ProcessingErrorAssertions
  # ERRORs logged during processing that don't mean the processing failed
  EXPECTED_PROCESSING_ERRORS = [
    # Submission#class_count logs this when the submission has no metrics yet.
    # Missing-label generation and term indexing ask for it before the metrics
    # step runs, and the ontologies report asks for it when run_metrics is off.
    # Each caller then falls back to counting the classes with a query.
    /\ANo calculated metrics found for \S+\. Unable to return total class count\.\z/
  ].freeze

  # Yields an ErrorRecordingLogger to the block, then fails if anything logged
  # an ERROR that is not in EXPECTED_PROCESSING_ERRORS or in allow.
  # Returns the logger.
  #
  #   assert_no_processing_errors { |logger| parser.process_queue_submissions(logger: logger) }
  def assert_no_processing_errors(allow: [])
    logger = ErrorRecordingLogger.new
    yield logger
    allowed = EXPECTED_PROCESSING_ERRORS + Array(allow)
    unexpected = logger.errors.reject { |error| allowed.any? { |pattern| pattern.match?(error) } }
    assert_empty unexpected, "Processing logged #{unexpected.length} unexpected ERROR(s):\n\n" \
                             "#{unexpected.map { |e| truncate_lines(e) }.join("\n\n")}\n"
    logger
  end

  private

  def truncate_lines(text, max = 15)
    lines = text.lines
    return text if lines.length <= max

    (lines.first(max) << "\t... #{lines.length - max} more lines\n").join
  end
end
