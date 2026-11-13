require_relative 'test_case'
require 'email_spec'

class TestOntologyPull < TestCase
  include EmailSpec::Helpers

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
    pull.do_remote_ontology_pull

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
    pull.do_remote_ontology_pull
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
    parser.process_queue_submissions

    # make sure there are now 2 submissions present
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 2, ont.submissions.length

    # verify that no new submission is created when the file has not changed
    parser.queue_submission(ont.submissions[0], actions)
    parser.process_queue_submissions
    ont = LinkedData::Models::Ontology.find(ontologies[0].id).first
    ont.bring(:submissions) if ont.bring?(:submissions)
    assert_equal 2, ont.submissions.length
  end

  # The remote file downloads fine (HTTP 200) but its content fails OWLAPI parsing.
  # Download failures (HTTP 404) are covered by test_pull_error_notification.
  def test_remote_pull_unparsable_file
    bad_url = 'http://ontology.example.test/unparsable.owl'
    stub_request(:head, bad_url).to_return(status: 200)
    stub_request(:get, bad_url).to_return(status: 200, body: 'this is not an ontology <<<')

    ontologies = init_ontologies(1)
    acronym = set_pull_location(ontologies[0], bad_url)
    clear_submission_dir(acronym, 2)

    log = StringIO.new
    # Call the helper directly: do_remote_ontology_pull's catch-all rescue would hide any exception.
    result = NcboCron::Helpers::OntologyHelper.do_ontology_pull(
      acronym, logger: Logger.new(log), add_to_queue: false
    )

    # the download succeeded and OWLAPI itself rejected the file
    assert_requested :get, bad_url, at_least_times: 1
    assert_match %r{Java call \[.*owlapi-wrapper.*/#{acronym}/2/unparsable\.owl}, log.string
    # owlapi-wrapper exits 0 on parse errors; the rejection shows up as its own error plus a missing owlapi.xrdf
    assert_match %r{OntologyParser - Problem parsing file:.*/unparsable\.owl}, log.string
    assert_match 'did not clear OWLAPI', log.string
    assert_match 'A new submission has NOT been created.', log.string

    assert_nil result, 'A rejected pull must not return a submission'
    assert_equal 1, submission_count(ontologies[0])
    refute Dir.exist?(submission_dir(acronym, 2)), 'The rejected submission folder should be removed'
  end

  # A gzip archive holding one unparsable file. unzip_submission (ontologies_linked_data) saves the
  # submission when it auto-sets masterFileName, which happens before OWLAPI runs, so a failed parse
  # must still leave no new submission behind. A second pull checks it doesn't pile up on every run.
  def test_remote_pull_unparsable_gzip_file
    bad_url = 'http://ontology.example.test/unparsable.owl.gz'
    stub_request(:head, bad_url).to_return(status: 200)
    stub_request(:get, bad_url).to_return(status: 200, body: gzip('this is not an ontology <<<'))

    ontologies = init_ontologies(1)
    acronym = set_pull_location(ontologies[0], bad_url)
    clear_submission_dir(acronym, 2)

    log = StringIO.new
    results = []
    submission_counts = 2.times.map do
      results << NcboCron::Helpers::OntologyHelper.do_ontology_pull(
        acronym, logger: Logger.new(log), add_to_queue: false
      )
      submission_count(ontologies[0])
    end

    # the archive was unpacked and OWLAPI itself rejected the payload
    assert_match %r{Java call \[.*owlapi-wrapper.*/#{acronym}/2/unzipped}, log.string
    assert_match %r{OntologyParser - Problem parsing file:.*/unzipped/}, log.string
    assert_match 'did not clear OWLAPI', log.string

    assert_equal [1, 1], submission_counts,
                 'An unparsable pulled archive must not create a submission (counts after each of two pulls)'
    assert_equal [nil, nil], results
    refute Dir.exist?(submission_dir(acronym, 2)), 'The rejected submission folder should be removed'
  end

  # The success path for a single-entry archive: the master file is set up front, the
  # submission is created once, and it is queued for processing.
  def test_remote_pull_gzip_file
    gz_url = 'http://ontology.example.test/BRO_v3.2.owl.gz'
    stub_request(:head, gz_url).to_return(status: 200)
    stub_request(:get, gz_url).to_return(status: 200, body: gzip(@@ontology_file_contents))

    ontologies = init_ontologies(1)
    acronym = set_pull_location(ontologies[0], gz_url)
    # other tests queue the same submission id
    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER

    new_sub = NcboCron::Helpers::OntologyHelper.do_ontology_pull(
      acronym, logger: Logger.new(StringIO.new), add_to_queue: true
    )

    refute_nil new_sub
    assert_equal 2, submission_count(ontologies[0])
    new_sub = LinkedData::Models::OntologySubmission.find(new_sub.id).first
    new_sub.bring_remaining
    assert_equal 2, new_sub.submissionId
    assert_equal 'BRO_v3.2.owl', new_sub.masterFileName
    assert File.exist?(File.join(submission_dir(acronym, 2), 'unzipped', 'BRO_v3.2.owl'))

    queue = NcboCron::Models::OntologySubmissionParser.new
    assert @@redis.hget(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER,
                        queue.get_prefixed_id(new_sub.id.to_s)), 'The new submission should be queued'
  end

  # Another pull of the same ontology holds the lock: this one skips it without downloading,
  # and leaves the other pull's lock alone. Once the lock is free, the pull runs and releases it.
  def test_pull_skips_ontology_already_being_pulled
    url = 'http://ontology.example.test/locked.owl'
    stub_remote_ontology_success(url)
    ontologies = init_ontologies(1)
    acronym = set_pull_location(ontologies[0], url)
    lock_key = "#{NcboCron::Helpers::OntologyHelper::PULL_LOCK_PREFIX}#{acronym}"
    @@redis.set(lock_key, 'another-pull')

    assert_nil pull(acronym)
    assert_not_requested :get, url
    assert_equal 1, submission_count(ontologies[0])
    assert_equal 'another-pull', @@redis.get(lock_key), 'A skipped pull must not release a lock it does not own'

    @@redis.del(lock_key)
    refute_nil pull(acronym), 'The pull should run once the lock is free'
    assert_equal 2, submission_count(ontologies[0])
    assert_nil @@redis.get(lock_key), 'A pull should release its lock when it finishes'
  ensure
    @@redis.del(lock_key) if lock_key
  end

  # A rejected pull removes only a folder it created: one that was already there is left alone.
  def test_rejected_pull_keeps_folder_it_did_not_create
    url = 'http://ontology.example.test/unparsable-existing-folder.owl'
    stub_request(:head, url).to_return(status: 200)
    stub_request(:get, url).to_return(status: 200, body: 'this is not an ontology <<<')
    ontologies = init_ontologies(1)
    acronym = set_pull_location(ontologies[0], url)
    leftover = File.join(submission_dir(acronym, 2), 'leftover.txt')
    FileUtils.mkdir_p(File.dirname(leftover))
    File.write(leftover, 'left by an earlier submission 2')

    assert_nil pull(acronym)
    assert_equal 1, submission_count(ontologies[0])
    assert File.exist?(leftover), 'A folder that existed before the pull must not be removed'
  end

  # Two pulls of one ontology pick the same submission id; the second fails validation as a
  # duplicate and must not remove the folder of the submission the first one saved.
  def test_rejected_pull_keeps_folder_of_saved_submission
    url = 'http://ontology.example.test/duplicate-id.owl'
    stub_remote_ontology_success(url)
    ontologies = init_ontologies(1)
    acronym = set_pull_location(ontologies[0], url)
    # Simulate the race: the next id is the one an existing submission already holds. Its folder
    # is gone, so this pull creates it, as the losing pull of a race would.
    LinkedData::Models::Ontology.any_instance.stubs(:next_submission_id).returns(1)
    FileUtils.rm_rf(submission_dir(acronym, 1))

    assert_nil pull(acronym)
    assert_equal 1, submission_count(ontologies[0])
    assert Dir.exist?(submission_dir(acronym, 1)), 'The saved submission\'s folder must not be removed'
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
    pull.do_remote_ontology_pull

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
    pull.do_remote_ontology_pull
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

    assert_nil new_sub, "a file that fails the OWLAPI check must not become a submission"
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

  def set_pull_location(ontology, url)
    ont = LinkedData::Models::Ontology.find(ontology.id).include(:acronym, :submissions).first
    sub = ont.submissions.first
    sub.bring_remaining
    sub.pullLocation = RDF::IRI.new(url)
    sub.save
    ont.acronym
  end

  def pull(acronym)
    NcboCron::Helpers::OntologyHelper.do_ontology_pull(acronym, logger: Logger.new(StringIO.new), add_to_queue: false)
  end

  def submission_count(ontology)
    LinkedData::Models::Ontology.find(ontology.id).include(:submissions).first.submissions.length
  end

  def submission_dir(acronym, submission_id)
    File.join(LinkedData.settings.repository_folder.to_s, acronym.to_s, submission_id.to_s)
  end

  # Teardown deletes submissions but not their folders, so an earlier test can leave this
  # one behind. A rejected pull keeps a folder it didn't create, so start without it.
  def clear_submission_dir(acronym, submission_id)
    FileUtils.rm_rf(submission_dir(acronym, submission_id))
  end

  def gzip(contents)
    io = StringIO.new(''.b)
    Zlib::GzipWriter.wrap(io) { |w| w.write(contents) }
    io.string
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
