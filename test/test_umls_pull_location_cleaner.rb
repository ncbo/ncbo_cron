require_relative 'test_case'

# The migration is a standalone script; load it without running its command line
load File.expand_path('../bin/migrations/clear_umls_pull_locations', __dir__)

class TestUmlsPullLocationCleaner < TestCase
  FAKE_KEY = '00000000-fake-test-key-000000000000'.freeze
  LEGACY_URL = "http://rest.bioontology.org/bioportal/ontologies/download/12345?apikey=#{FAKE_KEY}".freeze
  OTHER_URL = 'https://example.org/umls/release.ttl'.freeze
  OWL_FILE = File.expand_path('data/ontology_files/BRO_v3.2.owl', __dir__)

  def setup
    super
    create(acronym: 'UMLSPULL', format: 'UMLS', submission_count: 3)
    create(acronym: 'OWLPULL', format: 'OWL', submission_count: 2)
    submissions('OWLPULL-0').each { |s| set_pull_location(s, LEGACY_URL) }
  end

  def teardown
    LinkedData::Models::OntologySubmission.any_instance.unstub(:remote_file_exists?)
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    super
  end

  def test_clears_older_and_legacy_pull_locations
    seed_umls(LEGACY_URL, OTHER_URL, LEGACY_URL)

    results = cleaner.run

    assert_equal [:cleared, :cleared, :cleared], results.map(&:status), results.join("\n")
    assert_equal ['legacy REST URL', 'older submission', 'legacy REST URL'], results.map(&:message)
    assert_equal [nil, nil, nil], pull_locations('UMLSPULL-0')
    submissions('UMLSPULL-0').each do |sub|
      refute_nil sub.uploadFilePath, 'the uploaded file is kept'
      sub.bring_remaining
      assert sub.valid?, sub.errors.inspect
    end
    assert_equal [LEGACY_URL, LEGACY_URL], pull_locations('OWLPULL-0'), 'non-UMLS submissions are left alone'
  end

  def test_latest_submission_with_another_pull_location_is_kept
    seed_umls(OTHER_URL, nil, OTHER_URL)

    c = cleaner
    results = c.run

    assert_equal [:cleared, :no_pull_location, :kept_latest], results.map(&:status), results.join("\n")
    assert_equal [nil, nil, OTHER_URL], pull_locations('UMLSPULL-0')
    assert_empty c.failures, 'a kept latest submission is reported, not a failure'
    assert_includes c.summary, "UMLSPULL-0/3: kept_latest"
  end

  def test_pull_location_with_an_apikey_on_another_host_is_cleared
    keyed = "https://example.org/download?format=ttl&apikey=#{FAKE_KEY}"
    seed_umls(nil, nil, keyed)

    results = cleaner.run

    assert_equal :cleared, results.last.status
    assert_nil pull_locations('UMLSPULL-0').last
  end

  def test_api_keys_are_masked_in_the_log
    seed_umls(LEGACY_URL, nil, LEGACY_URL)
    log = StringIO.new

    cleaner(logger: Logger.new(log)).run

    refute_includes log.string, FAKE_KEY
    assert_includes log.string, 'apikey=***'
  end

  def test_dry_run_changes_nothing
    seed_umls(LEGACY_URL, OTHER_URL, LEGACY_URL)

    results = cleaner(dry_run: true).run

    assert_equal [:would_clear, :would_clear, :would_clear], results.map(&:status)
    assert_equal [LEGACY_URL, OTHER_URL, LEGACY_URL], pull_locations('UMLSPULL-0')
  end

  def test_rerun_leaves_cleared_submissions_alone
    seed_umls(LEGACY_URL, OTHER_URL, LEGACY_URL)
    cleaner.run

    results = cleaner.run

    assert_equal [:no_pull_location] * 3, results.map(&:status)
  end

  def test_only_named_ontologies_are_cleared
    seed_umls(LEGACY_URL, nil, nil)
    create(acronym: 'UMLSOTHER', format: 'UMLS', submission_count: 1)
    set_pull_location(submissions('UMLSOTHER-0').first, LEGACY_URL)

    results = cleaner.run(acronyms: ['umlsother-0'])

    assert_equal [['UMLSOTHER-0', :cleared]], results.map { |r| [r.acronym, r.status] }
    assert_equal [LEGACY_URL, nil, nil], pull_locations('UMLSPULL-0')
  end

  def test_submission_that_would_become_invalid_is_skipped
    seed_umls(LEGACY_URL, nil, nil)
    # Without an uploaded file, the pull location is all that keeps the submission valid
    LinkedData::Models::OntologySubmission.any_instance.stubs(:remote_file_exists?).returns(true)
    sub = submissions('UMLSPULL-0').first
    sub.bring_remaining
    sub.uploadFilePath = nil
    sub.save
    LinkedData::Models::OntologySubmission.any_instance.unstub(:remote_file_exists?)
    log = StringIO.new

    c = cleaner(logger: Logger.new(log))
    results = c.run

    assert_equal [:invalid, :no_pull_location, :no_pull_location], results.map(&:status), results.join("\n")
    assert_equal 1, c.failures.length
    assert_equal [LEGACY_URL, nil, nil], pull_locations('UMLSPULL-0')
    refute_includes log.string, FAKE_KEY
  end

  def test_legacy_detection_and_masking
    assert UmlsPullLocationCleaner.legacy?(LEGACY_URL)
    assert UmlsPullLocationCleaner.legacy?('http://REST.bioontology.org/bioportal/virtual/download/1')
    assert UmlsPullLocationCleaner.legacy?('https://example.org/file.ttl?ApiKey=abc')
    refute UmlsPullLocationCleaner.legacy?(OTHER_URL)
    refute UmlsPullLocationCleaner.legacy?('https://example.org/rest.bioontology.org.ttl')

    assert_equal 'http://x/download?apikey=***&format=ttl',
                 UmlsPullLocationCleaner.mask('http://x/download?apikey=secret&format=ttl')
    assert_equal 'see https://x/y?APIKEY=*** for details', UmlsPullLocationCleaner.mask('see https://x/y?APIKEY=k1 for details')
  end

  private

  def cleaner(logger: Logger.new(StringIO.new), **options)
    UmlsPullLocationCleaner.new(logger: logger, **options)
  end

  def create(acronym:, format:, submission_count:)
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: submission_count, process_submission: false,
      acronym: acronym, ontology_format: format, file_path: OWL_FILE
    )
  end

  # Sets the pull locations of UMLSPULL-0's submissions, oldest first; nil leaves one unset
  def seed_umls(*locations)
    submissions('UMLSPULL-0').zip(locations).each do |sub, location|
      set_pull_location(sub, location) if location
    end
  end

  def set_pull_location(sub, url)
    sub.bring_remaining
    sub.pullLocation = RDF::URI.new(url)
    sub.save
  end

  def submissions(acronym)
    ont = LinkedData::Models::Ontology.find(acronym).include(:submissions).first
    ont.submissions.each { |s| s.bring(:submissionId, :uploadFilePath, :pullLocation) }
    ont.submissions.sort_by(&:submissionId)
  end

  def pull_locations(acronym)
    submissions(acronym).map { |s| s.pullLocation&.to_s }
  end
end
