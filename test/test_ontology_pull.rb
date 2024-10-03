require_relative 'test_case'
require 'rack'
require 'webrick'
require 'email_spec'

class TestOntologyPull < TestCase
  include EmailSpec::Helpers

  def self.before_suite
    ont_path = File.expand_path("../data/ontology_files/BRO_v3.2.owl", __FILE__)
    file = File.new(ont_path)
    @@port = TestCase.unused_port
    @@url = "http://localhost:#{@@port}/"
    @@thread = Thread.new do
      server = WEBrick::HTTPServer.new(Port: @@port)
      server.mount_proc '/' do |req, res|
        contents = file.read
        file.rewind
        res.body = contents
      end
      begin
        server.start
      ensure
        server.shutdown
      end
    end

    @@redis = Redis.new(:host => NcboCron.settings.redis_host, :port => NcboCron.settings.redis_port)
    db_size = @@redis.dbsize

    if db_size > 10_000
      puts "This test cannot be run. You are probably pointing to the wrong redis backend. "
      return
    end

    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
  end

  def self.after_suite
    Thread.kill(@@thread)
    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
  end

  def test_remote_ontology_pull
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
    new_sub.bring_remaining()
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

  def test_pull_error_notification
    server_port = TestCase.unused_port

    begin
      thread = Thread.new do
        server = WEBrick::HTTPServer.new(Port: server_port)
        server.mount_proc '/' do |req, res|
          res.body = 'Hello, world!'
        end
        begin
          server.start
        ensure
          server.shutdown
        end
      end
      assert_equal true, thread.alive?

      ont_count, acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(ont_count: 1, submission_count: 1, process_submission: false)
      ont = LinkedData::Models::Ontology.find(ontologies[0].id).include(:submissions).first
      ont.bring_remaining
      assert ont.valid?, "Invalid ontology: #{ont.errors}"
      assert_equal 1, ont.submissions.length, "Incorrect number of submissions for #{ont.acronym}"
      ont.save

      sub = ont.submissions.first
      sub.bring_remaining
      sub.pullLocation = RDF::IRI.new('http://localhost:' + server_port.to_s)
      assert sub.valid?, "Invalid submission: #{sub.errors}"
      sub.save
    ensure
      thread.kill
      sleep 3
      assert_equal false, thread.alive?
    end

    begin
      thread = Thread.new do
        # Restart the web server with a 404 response status, which renders
        # the pullLocation of the ontology submission in this test invalid.
        server = WEBrick::HTTPServer.new(Port: server_port)
        server.mount_proc '/' do |req, res|
          res.status = 404
        end
        begin
          server.start
        ensure
          server.shutdown
        end
      end
      assert_equal true, thread.alive?

      pull = NcboCron::Models::OntologyPull.new
      pull.do_remote_ontology_pull

      assert_match "] Load from URL failure for #{ont.name}", last_email_sent.subject
      user = ont.administeredBy[0]
      user.bring(:email)
      assert (last_email_sent.to.first.include? user.email) || (last_email_sent.header['Overridden-Sender'].value.include? user.email)
    ensure
      thread.kill
      sleep 3
      assert_equal false, thread.alive?
    end
  end

  def test_no_pull_location
    ont_count, acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(ont_count: 1, submission_count: 1, process_submission: false)
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

  private

  def init_ontologies(submission_count, process_submissions = false)
    ont_count, acronyms, ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
                            ont_count: 1, submission_count: submission_count, process_submission: process_submissions)
    ontologies[0].bring(:submissions) if ontologies[0].bring?(:submissions)
    ontologies[0].submissions.each do |sub|
      sub.bring_remaining()
      sub.pullLocation = RDF::IRI.new(@@url)
      sub.save() rescue binding.pry
    end
    ontologies
  end

end
