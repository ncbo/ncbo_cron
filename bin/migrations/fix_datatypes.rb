#!/usr/bin/env ruby

# Migration: repairs ontology submissions whose URI-typed metadata (documentation,
# homepage, publication, uri) is stored as plain literals or invalid URIs, and fills in
# a missing contact. Goo refuses to save such submissions, so anything that re-saves
# them (processing, archiving, other migrations) fails validation.
#
# Every submission of every ontology is checked, not only the latest. Values are read
# straight from the triplestore, because goo may load a literal as a String, which the
# URI validator rejects. Only submissions that need a change are written, and only after
# the repaired submission passes validation, so the script is safe to re-run.
#
#   bin/migrations/fix_datatypes.rb --dryrun
#   bin/migrations/fix_datatypes.rb -o ICD10CM,SNOMEDCT
#   bin/migrations/fix_datatypes.rb --latest-only
#   bin/migrations/fix_datatypes.rb
#
# test/test_fix_datatypes.rb loads this file without running the command line.

require 'logger'
require 'fileutils'

class SubmissionDatatypeFixer
  DEFAULT_URI = 'http://www.example.com'.freeze
  UNKNOWN_CONTACT = { name: 'Unknown', email: 'noreply@bioontology.org' }.freeze

  # is_single: keep one value; is_required: assign DEFAULT_URI when there is none.
  # legacy_predicates: older predicates the attribute was stored under. Their values are
  # read too and moved to the model's predicate.
  URI_ATTRIBUTES_TO_FIX = {
    documentation: { is_single: true, is_required: false },
    homepage: { is_single: true, is_required: false, legacy_predicates: [[:metadata, 'homepage']] },
    publication: { is_single: false, is_required: false },
    uri: { is_single: true, is_required: true }
  }.freeze

  FAILED = %i[invalid error].freeze

  Result = Struct.new(:acronym, :submission_id, :status, :changes, :message, keyword_init: true) do
    def failed?
      FAILED.include?(status)
    end

    def to_s
      line = "#{acronym}/#{submission_id}: #{status}"
      line += " (#{message})" if message
      line += "\n    #{changes.join("\n    ")}" unless changes.nil? || changes.empty?
      line
    end
  end

  attr_reader :results

  def initialize(logger: Logger.new($stdout), dry_run: false, latest_only: false)
    @logger = logger
    @dry_run = dry_run
    @latest_only = latest_only
    @results = []
  end

  # acronyms limits the run to those ontologies; nil means every ontology
  def run(acronyms: nil)
    @results = []
    onts = ontologies(acronyms)
    scope = @latest_only ? 'latest submission' : 'all submissions'
    @logger.info("Checking #{scope} of #{onts.length} ontologies#{' (dry run)' if @dry_run}")

    onts.each do |ont|
      submissions_of(ont).each do |sub|
        result = fix(ont, sub)
        @results << result
        result.failed? ? @logger.error(result.to_s) : @logger.info(result.to_s)
      end
    end

    summary = @results.group_by(&:status).map { |status, rs| "#{status}: #{rs.length}" }.join(', ')
    @logger.info("Checked #{@results.length} submissions#{" (#{summary})" unless summary.empty?}")
    @results
  end

  def failures
    @results.select(&:failed?)
  end

  # Brings one submission's URI attributes and contact into a state goo will save
  def fix(ont, sub)
    sub.bring_remaining
    changes = []
    fixed_attrs = []

    URI_ATTRIBUTES_TO_FIX.each do |attr, settings|
      stored = stored_values(sub, attr)
      new_value = repaired_value(attr, settings, stored)
      next if new_value == :unchanged

      sub.send("#{attr}=", new_value)
      fixed_attrs << attr
      changes << "#{attr}: #{describe(stored.map(&:last))} -> #{describe(Array(new_value))}"
    end

    if sub.contact.nil? || sub.contact.empty?
      sub.contact = [fallback_contact]
      changes << "contact: none -> #{UNKNOWN_CONTACT[:email]}"
    end

    return result(ont, sub, :ok) if changes.empty?

    unless submission_valid?(sub)
      return result(ont, sub, :invalid, "not saved: #{sub.errors}", changes: changes)
    end
    return result(ont, sub, :would_fix, changes: changes) if @dry_run

    # Goo deletes only the values it loaded, in the form it loaded them, so remove the
    # stored triples of the repaired attributes first and let save write the new ones.
    fixed_attrs.each { |attr| delete_stored_values(sub, attr) }
    sub.save
    result(ont, sub, :fixed, changes: changes)
  rescue StandardError => e
    result(ont, sub, :error, "#{e.class}: #{e.message}", changes: changes)
  end

  private

  def ontologies(acronyms)
    if acronyms
      acronyms.map(&:upcase).uniq.filter_map do |acronym|
        ont = LinkedData::Models::Ontology.find(acronym).include(:acronym).first
        @logger.warn("#{acronym}: ontology not found") unless ont
        ont
      end
    else
      LinkedData::Models::Ontology.where.include(:acronym).all.sort_by(&:acronym)
    end
  end

  def submissions_of(ont)
    if @latest_only
      [ont.latest_submission(status: :any)].compact
    else
      ont.bring(submissions: [:submissionId])
      ont.submissions.sort_by(&:submissionId)
    end
  end

  def predicates(attr)
    model = LinkedData::Models::OntologySubmission.attribute_uri(attr)
    legacy = URI_ATTRIBUTES_TO_FIX[attr].fetch(:legacy_predicates, []).map do |prefix, name|
      RDF::URI.new("#{Goo.namespaces[prefix]}#{name}")
    end
    [model, *legacy]
  end

  # [[predicate, RDF term], ...] as stored, model predicate first
  def stored_values(sub, attr)
    predicates(attr).flat_map do |predicate|
      query = <<~SPARQL
        SELECT ?o
        FROM <#{sub.graph}>
        WHERE { <#{sub.id}> <#{predicate}> ?o . }
      SPARQL
      Goo.sparql_query_client.query(query).map { |solution| [predicate, solution[:o]] }
    end
  end

  # The value to assign, or :unchanged when the stored values are already valid URIs
  # under the model's predicate
  def repaired_value(attr, settings, stored)
    model_predicate = predicates(attr).first
    if stored.empty?
      return settings[:is_required] ? RDF::URI.new(DEFAULT_URI) : :unchanged
    end

    already_valid = stored.all? { |predicate, term| predicate == model_predicate && valid_uri_term?(term) }
    already_valid &&= stored.length == 1 if settings[:is_single]
    return :unchanged if already_valid

    repaired = stored.map { |_, term| fix_invalid_uri(term.to_s, attr) }.uniq
    settings[:is_single] ? repaired.first : repaired
  end

  def valid_uri_term?(term)
    term.is_a?(RDF::URI) && term.valid?
  end

  def fix_invalid_uri(value, attr, default_scheme: 'http')
    cleaned = value.to_s.strip
    if cleaned.empty?
      @logger.warn("#{attr}: empty value replaced with #{DEFAULT_URI}")
      return RDF::URI.new(DEFAULT_URI)
    end

    uri = RDF::URI.new(cleaned)
    return uri if uri.valid?

    unless cleaned.match?(%r{\Ahttps?://})
      corrected = RDF::URI.new("#{default_scheme}://#{cleaned}")
      return corrected if corrected.valid?
    end

    @logger.warn("#{attr}: '#{value}' is not a valid URI, replaced with #{DEFAULT_URI}")
    RDF::URI.new(DEFAULT_URI)
  end

  def delete_stored_values(sub, attr)
    predicates(attr).each do |predicate|
      Goo.sparql_update_client.update(<<~SPARQL)
        DELETE { GRAPH <#{sub.graph}> { <#{sub.id}> <#{predicate}> ?o . } }
        WHERE { GRAPH <#{sub.graph}> { <#{sub.id}> <#{predicate}> ?o . } }
      SPARQL
    end
  end

  # Older versions of the submission model raised from valid? when an upload file was
  # missing. Create an empty placeholder so validation can finish, as before.
  def submission_valid?(sub)
    return true if sub.valid?

    # A dry run doesn't create the fallback contact, which goo reports as non-persistent
    unsaved_contact = @dry_run && sub.contact == [@fallback_contact] && !@fallback_contact.persistent?
    return false unless unsaved_contact

    sub.errors.delete(:contact)
    sub.errors.empty?
  rescue ArgumentError => e
    match = e.message.match(/File path (.+?) not found/)
    raise unless match && !@dry_run

    FileUtils.mkdir_p(File.dirname(match[1]))
    File.write(match[1], '')
    @logger.warn("Created missing file #{match[1]} to allow validation to proceed")
    sub.valid?
  end

  def fallback_contact
    @fallback_contact ||= begin
      contact = LinkedData::Models::Contact.where(email: UNKNOWN_CONTACT[:email]).first
      contact ||= LinkedData::Models::Contact.new(UNKNOWN_CONTACT.dup)
      contact.save unless contact.persistent? || @dry_run
      contact
    end
  end

  def describe(values)
    return 'none' if values.empty?

    values.map { |v| v.is_a?(RDF::Literal) ? v.inspect : "<#{v}>" }.join(', ')
  end

  def result(ont, sub, status, message = nil, changes: [])
    Result.new(acronym: ont.acronym, submission_id: sub.submissionId, status: status,
               changes: changes, message: message)
  end
end

if $PROGRAM_NAME == __FILE__
  # Exit cleanly from an early interrupt
  Signal.trap('INT') { exit 1 }

  require 'bundler/setup'
  require 'optparse'

  options = { dry_run: false, latest_only: false, ontologies: nil, logfile: nil }
  OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename(__FILE__)} [options]"
    opts.on('-o', '--ontologies ACRONYM[,ACRONYM,...]', 'Only these ontologies (default: all of them)') do |acronyms|
      options[:ontologies] = acronyms.split(',').map(&:strip).reject(&:empty?)
    end
    opts.on('-d', '--dryrun', 'Report what would be fixed; change nothing') { options[:dry_run] = true }
    opts.on('--latest-only', 'Only check the latest submission of each ontology') { options[:latest_only] = true }
    opts.on('-l', '--logfile FILE', 'Also write the log to FILE') { |file| options[:logfile] = file }
    opts.on('-h', '--help', 'Display this screen') do
      puts opts
      exit
    end
  end.parse!

  require_relative '../../lib/ncbo_cron'
  config_exists = File.exist?(File.expand_path('../../../config/config.rb', __FILE__))
  abort('Please create a config/config.rb file using the config/config.rb.sample as a template') unless config_exists
  require_relative '../../config/config'

  outputs = [$stdout]
  outputs << File.open(options[:logfile], 'a') if options[:logfile]
  logger = Logger.new(Class.new {
    define_method(:write) { |msg| outputs.each { |o| o.write(msg); o.flush } }
    define_method(:close) { outputs.drop(1).each(&:close) }
  }.new)

  logger.info("Triplestore: #{LinkedData.settings.goo_host}")

  fixer = SubmissionDatatypeFixer.new(logger: logger, dry_run: options[:dry_run],
                                      latest_only: options[:latest_only])
  fixer.run(acronyms: options[:ontologies])

  failures = fixer.failures
  unless failures.empty?
    logger.error("#{failures.length} submissions could not be fixed:\n  #{failures.join("\n  ")}")
    exit 1
  end
end
