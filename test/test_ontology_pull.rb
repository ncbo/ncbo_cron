require_relative 'test_case'
require_relative 'support/processing_error_assertions'
require 'email_spec'

class TestOntologyPull < TestCase
  include EmailSpec::Helpers
  include ProcessingErrorAssertions

  def before_all
    super
    ont_path = File.expand_path('../data/ontology_files/BRO_v3.2.owl', __FILE__)
    @@ontology_file_contents = File.binread(ont_path)
    @@url = 'http://ontology.example.test/BRO_v3.2.owl'

    @@redis = Redis.new(host: NcboCron.settings.redis_host, port: NcboCron.settings.redis_port)
    db_size = @@redis.dbsize

    if db_size > 10_000
      puts 'This test cannot be run. You are probably pointing to the wrong redis backend.'
      return
    end

    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
  end

  def setup
    super
    # Pulls queue the submissions they create. Left in the queue, they would be
    # processed by a later test's process_queue_submissions after their
    # ontology was recreated, and fail as "not in the system".
    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
  end

  def after_all
    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
    super
  end

  def test_remote_ontology_pull
    stub_remote_ontology_success(@@url)
    ontologies = init_ontologies(1)
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 1, ont.submissions.length

    pull = NcboCron::Models::OntologyPull.new
    assert_no_processing_errors { |logger| pull.do_remote_ontology_pull(logger: logger) }

    # check that the pull creates a new submission when the file has changed
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 2, ont.submissions.length

    new_sub = ont.latest_submission(status: :uploaded)
    new_sub.bring_remaining
    assert_equal 2, new_sub.submissionId
    assert_equal ontologies[0].submissions[0].pullLocation, new_sub.pullLocation
    assert ontologies[0].submissions[0].released < new_sub.released

    # test Redis queue
    queue = NcboCron::Models::OntologySubmissionParser.new
    val = @@redis.hget(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER, queue.get_prefixed_id(new_sub.id.to_s))
    options = MultiJson.load(val, symbolize_keys: true)
    assert_equal NcboCron::Models::OntologySubmissionParser::ACTIONS, options

    # check that the pull does not create a new submission when the file has not changed
    ontologies = init_ontologies(2)
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 2, ont.submissions.length
    assert_no_processing_errors { |logger| pull.do_remote_ontology_pull(logger: logger) }
    assert_equal 2, ont.submissions.length
  end

  def test_remote_pull_parsing_action
    stub_remote_ontology_success(@@url)
    ontologies = init_ontologies(1, process_submissions: true)
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 1, ont.submissions.length

    # add this ontology to submission queue with :remote_pull action enabled
    parser = NcboCron::Models::OntologySubmissionParser.new
    actions = NcboCron::Models::OntologySubmissionParser::ACTIONS.dup
    actions[:remote_pull] = true
    parser.queue_submission(ont.submissions[0], actions)
    assert_no_processing_errors { |logger| parser.process_queue_submissions(logger: logger) }

    # make sure there are now 2 submissions present
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 2, ont.submissions.length

    # verify that no new submission is created when the file has not changed
    parser.queue_submission(ont.submissions[0], actions)
    assert_no_processing_errors { |logger| parser.process_queue_submissions(logger: logger) }
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 2, ont.submissions.length
  end

  def test_pull_error_notification
    error_url = 'http://ontology.example.test/404.owl'
    stub_remote_ontology_not_found(error_url)

    _ont_count, _acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: 1, process_submission: false
    )
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).include(:submissions).first
    ont.bring_remaining
    assert ont.valid?, "Invalid ontology: #{ont.errors}"
    assert_equal 1, ont.submissions.length, "Incorrect number of submissions for #{ont.acronym}"
    ont.save

    sub = ont.submissions.first
    sub.bring_remaining
    sub.pullLocation = RDF::IRI.new(error_url)
    assert sub.valid?, "Invalid submission: #{sub.errors}"
    sub.save

    pull = NcboCron::Models::OntologyPull.new
    assert_no_processing_errors { |logger| pull.do_remote_ontology_pull(logger: logger) }

    assert_match "] Load from URL failure for #{ont.name}", last_email_sent.subject
    user = ont.administeredBy[0]
    user.bring(:email)
    assert(
      last_email_sent.to.first.include?(user.email) ||
      last_email_sent.header['Overridden-Sender'].value.include?(user.email)
    )
  end

  def test_no_pull_location
    _ont_count, _acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: 1, process_submission: false
    )
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).include(:submissions).first
    ont.bring_remaining
    assert ont.valid?, "Invalid ontology: #{ont.errors}"
    assert_equal 1, ont.submissions.length, "Incorrect number of submissions for #{ont.acronym}"
    ont.save

    sub = ont.submissions.first
    sub.bring_remaining
    assert sub.valid?, "Invalid submission: #{sub.errors}"
    assert sub.pullLocation.nil?
    sub.save

    # Check that we don't attempt to pull ontologies with no pull locations.
    reset_mailer
    pull = NcboCron::Models::OntologyPull.new
    assert_no_processing_errors { |logger| pull.do_remote_ontology_pull(logger: logger) }
    assert Pony.deliveries.empty?
  end

  def teardown
    # The ontologies made for the create_submission tests would otherwise be
    # swept by every later pull test
    %w[CREATE-UMLS-0 CREATE-OWL-0].each do |acronym|
      ont = LinkedData::Models::Ontology.find(acronym).include(:submissions).first
      next if ont.nil?

      ont.submissions.each(&:delete)
      ont.delete
    end
    super
  end

  def test_create_submission_skips_owlapi_check_for_umls
    ont, sub = init_ontology_for_create("UMLS")
    LinkedData::Models::OntologySubmission.any_instance.expects(:parsable?).never

    new_sub = create_submission_from_file(ont, sub)

    assert_new_submission_saved(ont, new_sub)
  end

  def test_create_submission_checks_umls_with_owlapi_when_umls_parse_is_off
    old_setting = LinkedData.settings.umls_owlapi_parse
    LinkedData.settings.umls_owlapi_parse = false
    ont, sub = init_ontology_for_create("UMLS")
    # Off, this parse is what writes metrics.csv with the max depth
    LinkedData::Models::OntologySubmission.any_instance.expects(:parsable?).once.returns(true)

    new_sub = create_submission_from_file(ont, sub)

    assert_new_submission_saved(ont, new_sub)
  ensure
    LinkedData.settings.umls_owlapi_parse = old_setting
  end

  def test_create_submission_checks_other_formats_with_owlapi
    ont, sub = init_ontology_for_create("OWL")
    LinkedData::Models::OntologySubmission.any_instance.expects(:parsable?).once.returns(false)

    new_sub = create_submission_from_file(ont, sub)

    refute new_sub.persistent?, "a file that fails the OWLAPI check must not become a submission"
    ont = LinkedData::Models::Ontology.find(ont.id).include(:submissions).first
    assert_equal 1, ont.submissions.length
  end

  private

  def init_ontology_for_create(format)
    _ont_count, _acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: 1, process_submission: false,
      acronym: "CREATE-#{format}", ontology_format: format
    )
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).include(:acronym, :submissions).first
    sub = ont.submissions.first
    sub.bring_remaining
    assert sub.hasOntologyLanguage.id.to_s.end_with?(format)
    [ont, sub]
  end

  def create_submission_from_file(ont, sub)
    file_path = File.expand_path('../data/ontology_files/BRO_v3.2.owl', __FILE__)
    # Not queued, so later tests that process the queue don't pick it up
    NcboCron::Helpers::OntologyHelper.create_submission(ont, sub, file_path, File.basename(file_path),
                                                        Logger.new(StringIO.new), false)
  end

  def assert_new_submission_saved(ont, new_sub)
    assert new_sub.persistent?, "submission was not saved: #{new_sub.errors}"
    ont = LinkedData::Models::Ontology.find(ont.id).include(:submissions).first
    assert_equal 2, ont.submissions.length
  end

  def init_ontologies(submission_count, process_submissions = false)
    ont_count, acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: submission_count, process_submission: process_submissions
    )
    ontologies[0].bring(:submissions) if ontologies[0].bring?(:submissions)
    ontologies[0].submissions.each do |sub|
      sub.bring_remaining
      sub.pullLocation = RDF::IRI.new(@@url)
      sub.save rescue binding.pry
    end
    ontologies
  end

  def stub_remote_ontology_success(url)
    stub_request(:head, url).to_return(status: 200)
    stub_request(:get, url).to_return(status: 200, body: @@ontology_file_contents)
  end

  def stub_remote_ontology_not_found(url)
    stub_request(:head, url).to_return(status: 404)
    stub_request(:get, url).to_return(status: 404)
  end
end
