require_relative 'test_case'
require 'json'
require 'multi_json'
require 'redis'

class TestOntologySubmissionParser < TestCase
  def setup
    super
    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
  end

  def before_all
    super
    @@redis = Redis.new(host: NcboCron.settings.redis_host, port: NcboCron.settings.redis_port)
    db_size = @@redis.dbsize

    if db_size > 10_000
      puts 'This test cannot be run. You are probably pointing to the wrong Redis backend.'
      return
    end

    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER

    @@ont_count, @@acronyms, @@ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 2,
      submission_count: 2,
      process_submission: false
    )
  end

  def after_all
    @@redis.del NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    super
  end

  def test_queue_submission
    parser = NcboCron::Models::OntologySubmissionParser.new

    o1 = @@ontologies[0]
    o1.bring(:submissions) if o1.bring?(:submissions)
    parser.queue_submission(o1.submissions[0], { dummy_action: true })
    val = @@redis.hget(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER,
                       parser.get_prefixed_id(o1.submissions[0].id.to_s))
    assert_nil val

    parser.queue_submission(o1.submissions[0], { dummy_action: true, index_all_data: false, index_search: false,
                                                 metrics: true, process_annotator: true, another_dummy_action: true, all: true })
    val = @@redis.hget(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER,
                       parser.get_prefixed_id(o1.submissions[0].id.to_s))
    options = MultiJson.load(val, symbolize_keys: true)
    assert_equal NcboCron::Models::OntologySubmissionParser::ACTIONS, options

    o2 = @@ontologies[1]
    o2.bring(:submissions) if o2.bring?(:submissions)
    parser.queue_submission(o2.submissions[0], { process_rdf: false, index_search: true, index_all_data: true,
                                                 metrics: true, process_annotator: false })
    val = @@redis.hget(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER,
                       parser.get_prefixed_id(o2.submissions[0].id.to_s))
    options = MultiJson.load(val, symbolize_keys: true)
    assert_equal({ process_rdf: false, index_search: true, index_all_data: true, process_annotator: false }, options)
  end

  def test_parse_submissions
    parser = NcboCron::Models::OntologySubmissionParser.new
    archived_submissions = []
    not_archived_submissions = []

    o1 = @@ontologies[0]
    o1.bring(:submissions)
    o1_sub1 = o1.submissions.select { |x| x.id.to_s["/submissions/1"]}.first
    o1_sub1.bring(:submissionStatus)
    o1_sub2 = o1.submissions.select { |x| x.id.to_s["/submissions/2"]}.first
    o1_sub2.bring(:submissionStatus)

    o2 = @@ontologies[1]
    o2.bring(:submissions)
    o2_sub1 = o2.submissions.select { |x| x.id.to_s["/submissions/1"]}.first
    o2_sub1.bring(:submissionStatus)
    o2_sub2 = o2.submissions.select { |x| x.id.to_s["/submissions/2"]}.first
    o2_sub2.bring(:submissionStatus)

    options_o1 = {
      dummy_action: true, process_rdf: true, index_search: true, index_all_data: true, index_properties: true,
      diff: true, dummy_metrics: false, run_metrics: false, process_annotator: false,
      another_dummy_action: false, all: false
    }

    options_o2 = {
      dummy_action: false, process_rdf: true, index_search: false, index_all_data: false, index_properties: false,
      diff: true, dummy_metrics: true, run_metrics: false, process_annotator: true,
      another_dummy_action: true, all: false
    }

    parser.queue_submission(o1_sub1, options_o1)
    parser.queue_submission(o2_sub1, options_o2)

    assert_no_processing_failures parser.process_queue_submissions

    parser.queue_submission(o1_sub2, options_o1)
    parser.queue_submission(o2_sub2, options_o2)

    assert_no_processing_failures parser.process_queue_submissions

    o1_sub1 = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(o1_sub1.id)).first
    o1_sub1.bring(:submissionStatus)
    o1_sub2 = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(o1_sub2.id)).first
    o1_sub2.bring(:submissionStatus)

    o2_sub1 = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(o2_sub1.id)).first
    o2_sub1.bring(:submissionStatus)
    o2_sub2 = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(o2_sub2.id)).first
    o2_sub2.bring(:submissionStatus)

    o1_sub1_statusCodes = LinkedData::Models::SubmissionStatus.get_status_codes(o1_sub1.submissionStatus)
    o1_sub2_statusCodes = LinkedData::Models::SubmissionStatus.get_status_codes(o1_sub2.submissionStatus)
    o2_sub1_statusCodes = LinkedData::Models::SubmissionStatus.get_status_codes(o2_sub1.submissionStatus)
    o2_sub2_statusCodes = LinkedData::Models::SubmissionStatus.get_status_codes(o2_sub2.submissionStatus)

    assert_equal [], ["ARCHIVED"] - o1_sub1_statusCodes
    assert_equal [], ["UPLOADED", "RDF", "RDF_LABELS", "INDEXED", "INDEXED_PROPERTIES", "DIFF"] - o1_sub2_statusCodes
    assert_equal [], ["ARCHIVED"] - o2_sub1_statusCodes
    assert_equal [], ["UPLOADED", "RDF", "RDF_LABELS", "ANNOTATOR", "DIFF"] - o2_sub2_statusCodes
    assert_no_error_statuses o1_sub2
    assert_no_error_statuses o2_sub2

    archived_submissions << o1_sub1
    archived_submissions << o2_sub1
    not_archived_submissions << o1_sub2
    not_archived_submissions << o2_sub2

    logger = Logger.new(STDOUT)

    not_archived_submissions.each do |s|
      assert LinkedData::Models::Class.where.in(s).all.count > 50
    end

    parser.process_flush_classes(logger)

    archived_submissions.each do |s|
      assert_equal 0, LinkedData::Models::Class.where.in(s).all.count
    end

    not_archived_submissions.each do |s|
      assert LinkedData::Models::Class.where.in(s).all.count > 50
    end

    ont_submission_iter = NcboCron::Models::QueryWarmer.new(logger).run
    assert ont_submission_iter >= 0

    o1 = @@ontologies[0]
    o1.delete(skip_archiving: true)
    zombies = parser.zombie_classes_graphs
    assert_equal 1, zombies.length
    assert zombies.first["/TEST-ONT-0/submissions/2"]
    o2 = @@ontologies[1]
    o2.delete
    @@ont_count, @@acronyms, @@ontologies = LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 2,
      submission_count: 2,
      process_submission: false
    )
  end

  def test_extract_metadata
    parser = NcboCron::Models::OntologySubmissionParser.new

    o1 = @@ontologies[0]
    o1.bring(:submissions)
    o1_sub1 = o1.submissions.select { |x| x.id.to_s["/submissions/1"]}.first
    o1_sub1.bring(:submissionStatus)
    o1_sub2 = o1.submissions.select { |x| x.id.to_s["/submissions/2"]}.first
    o1_sub2.bring(:submissionStatus)

    o2 = @@ontologies[1]
    o2.bring(:submissions)
    o2_sub1 = o2.submissions.select { |x| x.id.to_s["/submissions/1"]}.first
    o2_sub1.bring(:submissionStatus)
    o2_sub2 = o2.submissions.select { |x| x.id.to_s["/submissions/2"]}.first
    o2_sub2.bring(:submissionStatus)

    options_o1 = { :all => true, :params => { :homepage => "o1 homepage" }}

    options_o2 = {
      dummy_action: false, process_rdf: true, index_search: false, :diff => true,
      dummy_metrics: true, run_metrics: false, process_annotator: true,
      another_dummy_action: true, all: false, :params => { "homepage" => "o2 homepage" }
    }

    parser.queue_submission(o1_sub1, options_o1)
    parser.queue_submission(o2_sub1, options_o2)
    assert_no_processing_failures parser.process_queue_submissions

    o1_sub1 = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(o1_sub1.id)).first
    o1_sub1.bring(:submissionStatus)

    o2_sub1 = LinkedData::Models::OntologySubmission.find(RDF::IRI.new(o2_sub1.id)).first
    o2_sub1.bring(:submissionStatus)

    o1_sub1_statusCodes = LinkedData::Models::SubmissionStatus.get_status_codes(o1_sub1.submissionStatus)
    o2_sub1_statusCodes = LinkedData::Models::SubmissionStatus.get_status_codes(o2_sub1.submissionStatus)

    assert_equal [], ["UPLOADED", "RDF", "RDF_LABELS", "INDEXED"] - o1_sub1_statusCodes
    assert_equal [], ["UPLOADED", "RDF", "RDF_LABELS", "ANNOTATOR"] - o2_sub1_statusCodes
    assert_no_error_statuses o1_sub1
    assert_no_error_statuses o2_sub1
  end

  def test_processing_exception_is_reported_and_the_queue_moves_on
    parser = NcboCron::Models::OntologySubmissionParser.new
    subs = first_submissions
    subs.each { |sub| parser.queue_submission(sub, { process_rdf: true }) }
    LinkedData::Models::OntologySubmission.any_instance.stubs(:process_submission)
                                          .raises(StandardError, 'simulated processing failure')

    failures = parser.process_queue_submissions(logger: Logger.new(StringIO.new))

    assert_equal subs.map { |sub| sub.id.to_s }.sort, failures.map(&:item).sort
    assert(failures.all? { |f| f.error.message == 'simulated processing failure' }, failures.join("\n"))
    assert_equal failures, parser.failures
    assert_empty @@redis.hgetall(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER)
  end

  def test_remote_pull_exception_is_reported_and_the_queue_moves_on
    parser = NcboCron::Models::OntologySubmissionParser.new
    subs = first_submissions
    subs.each { |sub| parser.queue_submission(sub, { remote_pull: true, process_rdf: true }) }
    NcboCron::Helpers::OntologyHelper.stubs(:do_ontology_pull).raises(StandardError, 'simulated pull failure')

    failures = parser.process_queue_submissions(logger: Logger.new(StringIO.new))

    # Each queued item is pulled and fails on its own, instead of the first
    # failure ending the run
    assert_equal subs.length, failures.length
    assert(failures.all? { |f| f.error.message == 'simulated pull failure' }, failures.join("\n"))
    assert_empty @@redis.hgetall(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER)
  end

  def test_invalid_queue_record_is_reported
    key = 'sub:http://data.bioontology.org/ontologies/BAD-RECORD/submissions/1'
    @@redis.hset(NcboCron::Models::OntologySubmissionParser::QUEUE_HOLDER, key, '{not json')
    parser = NcboCron::Models::OntologySubmissionParser.new

    failures = parser.process_queue_submissions(logger: Logger.new(StringIO.new))

    assert_equal [key], failures.map(&:item)
    assert_equal 'Invalid record in the parse queue', failures.first.message
  end

  def test_missing_submission_is_reported
    submission_id = 'http://data.bioontology.org/ontologies/NOT-THERE/submissions/1'
    parser = NcboCron::Models::OntologySubmissionParser.new

    failures = parser.process_submission(Logger.new(StringIO.new), submission_id, { process_rdf: true })

    assert_equal [submission_id], failures.map(&:item)
    assert_equal 'Submission is not in the system', failures.first.message
  end

  def test_annotator_failure_is_reported
    sub = first_submissions.first
    sub.stubs(:ready?).returns(true)
    Annotator::Models::NcboAnnotator.any_instance.stubs(:create_term_cache_for_submission)
                                    .raises(StandardError, 'simulated annotator failure')
    parser = NcboCron::Models::OntologySubmissionParser.new

    failure = parser.send(:process_annotator, Logger.new(StringIO.new), sub)

    assert_equal sub.id.to_s, failure.item
    assert_equal 'Annotator update failed', failure.message
    assert_equal 'simulated annotator failure', failure.error.message
  end

  private

  def first_submissions
    @@ontologies.map do |ont|
      ont.bring(:submissions)
      ont.submissions.find { |sub| sub.id.to_s.end_with?('/submissions/1') }
    end
  end

end
