#!/usr/bin/env ruby

# Migration: repairs ontology submissions whose URI-typed metadata (documentation,
# homepage, publication, uri) is stored as plain literals or invalid URIs, and fills in
# a missing contact, and removes ftp:// pull locations. Goo refuses to save such submissions, so anything that re-saves
# them (processing, archiving, other migrations) fails validation.
#
# Every submission of every ontology is checked, not only the latest. Values are read
# straight from the triplestore, because goo may load a literal as a String, which the
# URI validator rejects. Only submissions that need a change are written, and only after
# the repaired submission passes validation, so the script is safe to re-run. New values
# are written before the old ones are removed, so a failure part way leaves extra values
# behind, never missing ones; a re-run cleans them up.
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

  # is_single: keep one value. legacy_predicates: older predicates the attribute was
  # stored under; their values are read too and moved to the model's predicate.
  # An attribute the model requires (enforce :existence) gets DEFAULT_URI when it has no value.
  URI_ATTRIBUTES_TO_FIX = {
    documentation: { is_single: true },
    homepage: { is_single: true, legacy_predicates: [[:metadata, 'homepage']] },
    publication: { is_single: false },
    uri: { is_single: true }
  }.freeze

  # pullLocation is type :url, which accepts only http(s), and nothing pulls over ftp, so
  # these values are removed rather than repaired
  FTP_PULL_LOCATION = %r{\Aftp://}i

  FAILED = %i[invalid error].freeze
  URL_IN_TEXT = %r{https?://[^\s<>"'{}|\\^`]+}i
  # RDF::URI#valid? accepts these, but they are not allowed in a SPARQL IRI; N-Triples escapes
  # them as \uXXXX, which AllegroGraph rejects
  NOT_IN_IRI = /[\x00-\x20<>"{}|\\^`]/
  DOI_IN_TEXT = %r{\b(?:doi:\s*)?(10\.\d{4,9}/[^\s<>"']+)}i
  TRAILING_PUNCTUATION = /[.,;:)\]]+\z/

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
        if result.failed?
        @logger.error(result.to_s)
      elsif result.status.to_s.end_with?('still_invalid')
        @logger.warn(result.to_s)
      else
        @logger.info(result.to_s)
      end
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
    fixed = {} # attr => [stored values, new value]

    URI_ATTRIBUTES_TO_FIX.each do |attr, settings|
      stored = stored_values(sub, attr)
      new_value = repaired_value(attr, settings, stored)
      next if new_value == :unchanged

      sub.send("#{attr}=", new_value)
      fixed[attr] = [stored, new_value]
      changes << "#{attr}: #{describe(stored.map(&:last))} -> #{describe(Array(new_value))}"
    end

    ftp = ftp_pull_locations(sub)
    unless ftp.empty?
      kept = stored_pull_locations(sub) - ftp
      sub.pullLocation = kept.empty? ? nil : RDF::URI.new(kept.first.to_s)
      changes << "pullLocation: #{describe(ftp)} -> removed"
    end

    add_contact = sub.contact.nil? || sub.contact.empty?
    if add_contact
      sub.contact = [fallback_contact]
      changes << "contact: none -> #{UNKNOWN_CONTACT[:email]}"
    end

    return result(ont, sub, :ok) if changes.empty?

    # The repair is written as triples, so errors in attributes it doesn't touch (a bad
    # version) don't block it; those submissions are reported.
    other_errors = nil
    unless submission_valid?(sub)
      touched = fixed.keys + (add_contact ? [:contact] : []) + (ftp.empty? ? [] : [:pullLocation])
      errors = sub.errors || {}
      if errors.empty? || (errors.keys & touched).any?
        return result(ont, sub, :invalid, "not fixed: #{sub.errors}", changes: changes)
      end
      other_errors = "other invalid attributes: #{sub.errors}"
    end
    if @dry_run
      return result(ont, sub, other_errors ? :would_fix_still_invalid : :would_fix, other_errors, changes: changes)
    end

    write_repaired_values(sub, fixed, add_contact: add_contact, removed_pull_locations: ftp)
    leftovers = fixed.keys.reject { |attr| clean?(sub, attr) }
    leftovers << :pullLocation unless ftp_pull_locations(sub).empty?
    unless leftovers.empty?
      return result(ont, sub, :error, "saved, but #{leftovers.join(', ')} still hold old values",
                    changes: changes)
    end

    result(ont, sub, other_errors ? :fixed_still_invalid : :fixed, other_errors, changes: changes)
  rescue Exception => e # goo raises plain Exception, not StandardError
    raise unless e.is_a?(StandardError) || e.instance_of?(Exception)

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

  def stored_pull_locations(sub)
    predicate = LinkedData::Models::OntologySubmission.attribute_uri(:pullLocation)
    query = "SELECT ?o FROM <#{sub.graph}> WHERE { <#{sub.id}> <#{predicate}> ?o . }"
    Goo.sparql_query_client.query(query).map { |solution| solution[:o] }
  end

  def ftp_pull_locations(sub)
    stored_pull_locations(sub).select { |term| term.to_s.strip.match?(FTP_PULL_LOCATION) }
  end

  # The value to assign, or :unchanged when the stored values are already valid URIs
  # under the model's predicate
  def repaired_value(attr, settings, stored)
    if stored.empty?
      return required?(attr) ? RDF::URI.new(DEFAULT_URI) : :unchanged
    end
    return :unchanged if clean_values?(attr, settings, stored)

    repaired = stored.flat_map { |_, term| fix_invalid_uri(term.to_s, attr) }.uniq
    settings[:is_single] ? repaired.first : repaired
  end

  def clean_values?(attr, settings, stored)
    model_predicate = predicates(attr).first
    clean = stored.all? { |predicate, term| predicate == model_predicate && valid_uri_term?(term) }
    clean && stored.uniq.length == stored.length && (!settings[:is_single] || stored.length <= 1)
  end

  def clean?(sub, attr)
    clean_values?(attr, URI_ATTRIBUTES_TO_FIX[attr], stored_values(sub, attr))
  end

  def required?(attr)
    Array(LinkedData::Models::OntologySubmission.attribute_settings(attr)[:enforce]).include?(:existence)
  end

  def valid_uri_term?(term)
    term.is_a?(RDF::URI) && term.valid?
  end

  # The URIs to store for one stored value
  def fix_invalid_uri(value, attr, default_scheme: 'http')
    cleaned = value.to_s.strip
    if cleaned.empty?
      @logger.warn("#{attr}: empty value replaced with #{DEFAULT_URI}")
      return [RDF::URI.new(DEFAULT_URI)]
    end

    uri = RDF::URI.new(cleaned)
    return [uri] if storable?(uri)

    unless cleaned.match?(%r{\Ahttps?://}) || cleaned.match?(/\s/)
      corrected = RDF::URI.new("#{default_scheme}://#{cleaned}")
      return [corrected] if storable?(corrected)
    end

    # Free text such as a citation: keep the URLs or DOIs it mentions
    embedded = embedded_uris(cleaned)
    unless embedded.empty?
      @logger.warn("#{attr}: using #{embedded.map(&:to_s).join(', ')} found in '#{value}'")
      return embedded
    end

    # A URI followed by junk, such as "urn:lsid:bioontology.org:ENVO|$Revision 1.34$"
    leading = cleaned.split(/[|\s]/).first.to_s
    if leading.match?(/\A[a-z][a-z0-9+.-]*:\S/i) && storable?(RDF::URI.new(leading))
      @logger.warn("#{attr}: using #{leading} from the start of '#{value}'")
      return [RDF::URI.new(leading)]
    end

    @logger.warn("#{attr}: '#{value}' is not a valid URI, replaced with #{DEFAULT_URI}")
    [RDF::URI.new(DEFAULT_URI)]
  end

  def embedded_uris(text)
    found = text.scan(URL_IN_TEXT).map { |url| url.sub(TRAILING_PUNCTUATION, '') }
    if found.empty?
      found = text.scan(DOI_IN_TEXT).map { |(doi)| "https://doi.org/#{doi.sub(TRAILING_PUNCTUATION, '')}" }
    end
    found.uniq.map { |candidate| RDF::URI.new(candidate) }.select { |uri| storable?(uri) }
  end

  def storable?(uri)
    uri.valid? && !uri.to_s.match?(NOT_IN_IRI)
  end

  # Writes the repaired values with INSERT DATA / DELETE DATA on the exact stored terms
  # instead of goo's save. Goo deletes only the values it loaded, in the form it loaded
  # them, and on AllegroGraph, which keeps duplicate triples, re-inserting a value that is
  # already stored adds a second copy. Both calls name the graph, so goo can invalidate its
  # query cache; goo refuses plain-string updates when the cache is on.
  #
  # New values go in before old ones come out. A kept value that is stored more than once
  # is deleted (removing every copy) and inserted once again.
  def write_repaired_values(sub, fixed, add_contact:, removed_pull_locations: [])
    insert = RDF::Graph.new
    delete = RDF::Graph.new
    reinsert = RDF::Graph.new

    fixed.each do |attr, (stored, new_value)|
      model_predicate = predicates(attr).first
      kept = Array(new_value)
      current = stored.select { |predicate, term| predicate == model_predicate && term.is_a?(RDF::URI) }.map(&:last)
      kept.each do |term|
        copies = current.count { |t| t == term }
        insert << [sub.id, model_predicate, term] if copies.zero?
        next unless copies > 1

        delete << [sub.id, model_predicate, term]
        reinsert << [sub.id, model_predicate, term]
      end
      stored.each do |predicate, term|
        next if predicate == model_predicate && term.is_a?(RDF::URI) && kept.include?(term)

        delete << [sub.id, predicate, term]
      end
    end
    removed_pull_locations.each do |term|
      delete << [sub.id, LinkedData::Models::OntologySubmission.attribute_uri(:pullLocation), term]
    end
    if add_contact
      insert << [sub.id, LinkedData::Models::OntologySubmission.attribute_uri(:contact), fallback_contact.id]
    end

    client = Goo.sparql_update_client
    client.insert_data(insert, graph: sub.graph) unless insert.empty?
    client.delete_data(delete, graph: sub.graph) unless delete.empty?
    client.insert_data(reinsert, graph: sub.graph) unless reinsert.empty?
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

    values.map(&:to_ntriples).join(', ')
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
