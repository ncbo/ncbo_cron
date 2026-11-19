require_relative 'test_case'

# The migration is a standalone script; load it without running its command line
load File.expand_path('../bin/migrations/fix_datatypes.rb', __dir__)

class TestFixDatatypes < TestCase
  Submission = LinkedData::Models::OntologySubmission
  PUBLICATION = Submission.attribute_uri(:publication)
  DOCUMENTATION = Submission.attribute_uri(:documentation)
  HOMEPAGE = Submission.attribute_uri(:homepage)
  LEGACY_HOMEPAGE = RDF::URI.new("#{Goo.namespaces[:metadata]}homepage")
  URI_PREDICATE = Submission.attribute_uri(:uri)

  def setup
    super
    create('FIXDT', submission_count: 3)
    subs = submissions('FIXDT-0')

    # Older submissions hold literals, as old prod data does; the latest one is clean
    store(subs[0], PUBLICATION, RDF::Literal.new('http://pubs.example.org/1'),
          RDF::URI.new('http://pubs.example.org/2'))
    store(subs[1], PUBLICATION, RDF::Literal.new('pubs.example.org/3'))
    store(subs[1], DOCUMENTATION, RDF::Literal.new('http://docs.example.org'))
    store(subs[2], PUBLICATION, RDF::URI.new('http://pubs.example.org/latest'))
  end

  def teardown
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    super
  end

  def test_literal_publication_makes_an_older_submission_invalid
    sub = submissions('FIXDT-0').first
    sub.bring_remaining
    refute sub.valid?
    assert sub.errors.key?(:publication), sub.errors.inspect
  end

  def test_fixes_every_submission_not_just_the_latest
    results = fixer.run(acronyms: ['FIXDT-0'])

    assert_equal [[1, :fixed], [2, :fixed], [3, :ok]], results.map { |r| [r.submission_id, r.status] },
                 results.join("\n")
    subs = submissions('FIXDT-0')
    assert_equal [RDF::URI.new('http://pubs.example.org/1'), RDF::URI.new('http://pubs.example.org/2')],
                 stored(subs[0], PUBLICATION).sort_by(&:to_s)
    assert_equal [RDF::URI.new('http://pubs.example.org/3')], stored(subs[1], PUBLICATION)
    assert_equal [RDF::URI.new('http://docs.example.org')], stored(subs[1], DOCUMENTATION)
    assert_equal [RDF::URI.new('http://pubs.example.org/latest')], stored(subs[2], PUBLICATION)
    subs.each do |sub|
      sub.bring_remaining
      assert sub.valid?, "#{sub.id}: #{sub.errors.inspect}"
    end
  end

  def test_rerun_leaves_fixed_submissions_alone
    fixer.run
    results = fixer.run
    assert_equal [:ok, :ok, :ok], results.map(&:status)
  end

  def test_dry_run_changes_nothing
    results = fixer(dry_run: true).run

    assert_equal [:would_fix, :would_fix, :ok], results.map(&:status)
    assert_includes results.first.changes.first, '"http://pubs.example.org/1"'
    sub = submissions('FIXDT-0').first
    assert_includes stored(sub, PUBLICATION), RDF::Literal.new('http://pubs.example.org/1')
  end

  def test_latest_only_checks_just_the_latest_submission
    latest = submissions('FIXDT-0').last
    store(latest, PUBLICATION, RDF::Literal.new('http://pubs.example.org/latest-literal'))

    results = fixer(latest_only: true).run

    assert_equal [[3, :fixed]], results.map { |r| [r.submission_id, r.status] }
    assert(stored(latest, PUBLICATION).all? { |v| v.is_a?(RDF::URI) })
    assert_includes stored(submissions('FIXDT-0').first, PUBLICATION), RDF::Literal.new('http://pubs.example.org/1')
  end

  def test_only_named_ontologies_are_fixed
    create('FIXOTHER', submission_count: 1)
    store(submissions('FIXOTHER-0').first, PUBLICATION, RDF::Literal.new('http://pubs.example.org/other'))

    results = fixer.run(acronyms: ['fixother-0'])

    assert_equal [['FIXOTHER-0', :fixed]], results.map { |r| [r.acronym, r.status] }
    assert_includes stored(submissions('FIXDT-0').first, PUBLICATION), RDF::Literal.new('http://pubs.example.org/1')
  end

  def test_required_uri_is_repaired
    sub = submissions('FIXDT-0').first
    clear(sub, URI_PREDICATE)
    store(sub, URI_PREDICATE, RDF::Literal.new('not a uri'))

    fixer.run(acronyms: ['FIXDT-0'])

    assert_equal [RDF::URI.new(SubmissionDatatypeFixer::DEFAULT_URI)], stored(sub, URI_PREDICATE)
  end

  def test_missing_uri_is_left_alone_because_the_model_does_not_require_it
    sub = submissions('FIXDT-0').last
    clear(sub, URI_PREDICATE)

    results = fixer.run(acronyms: ['FIXDT-0'])

    assert_equal :ok, results.last.status, results.last.to_s
    assert_empty stored(sub, URI_PREDICATE)
  end

  def test_works_with_the_query_cache_on
    Goo.use_cache = true
    results = fixer.run(acronyms: ['FIXDT-0'])

    assert_equal [:fixed, :fixed, :ok], results.map(&:status), results.join("\n")
    assert_equal [RDF::URI.new('http://pubs.example.org/3')], stored(submissions('FIXDT-0')[1], PUBLICATION)
  ensure
    Goo.use_cache = false
  end

  def test_failed_save_keeps_the_stored_values
    Submission.any_instance.stubs(:save).raises(Exception, 'store unavailable')

    results = fixer.run(acronyms: ['FIXDT-0'])

    Submission.any_instance.unstub(:save)
    assert_equal [:error, :error, :ok], results.map(&:status)
    assert_includes results.first.message, 'store unavailable'
    assert_includes stored(submissions('FIXDT-0').first, PUBLICATION), RDF::Literal.new('http://pubs.example.org/1')
  end

  def test_missing_contact_gets_the_unknown_contact
    sub = submissions('FIXDT-0').last
    clear(sub, Submission.attribute_uri(:contact))
    LinkedData::Models::Contact.where(email: SubmissionDatatypeFixer::UNKNOWN_CONTACT[:email]).all.each(&:delete)

    r = fixer(dry_run: true).run(acronyms: ['FIXDT-0']).last
    assert_equal :would_fix, r.status, r.to_s
    assert_empty LinkedData::Models::Contact.where(email: SubmissionDatatypeFixer::UNKNOWN_CONTACT[:email]).all,
                 'a dry run creates no contact'

    assert_equal :fixed, fixer.run(acronyms: ['FIXDT-0']).last.status
    contact = Submission.find(sub.id).include(contact: [:email]).first.contact
    assert_equal [SubmissionDatatypeFixer::UNKNOWN_CONTACT[:email]], contact.map(&:email)
  end

  def test_homepage_under_the_legacy_predicate_moves_to_the_model_predicate
    sub = submissions('FIXDT-0').last
    store(sub, LEGACY_HOMEPAGE, RDF::Literal.new('http://home.example.org'))

    results = fixer.run(acronyms: ['FIXDT-0'])

    assert_equal :fixed, results.last.status, results.last.to_s
    assert_empty stored(sub, LEGACY_HOMEPAGE)
    assert_equal [RDF::URI.new('http://home.example.org')], stored(sub, HOMEPAGE)
  end

  def test_invalid_submission_keeps_its_stored_values
    Submission.any_instance.stubs(:valid?).returns(false)

    f = fixer
    results = f.run(acronyms: ['FIXDT-0'])

    Submission.any_instance.unstub(:valid?)
    assert_equal [:invalid, :invalid, :ok], results.map(&:status)
    assert_equal 2, f.failures.length
    sub = submissions('FIXDT-0').first
    assert_includes stored(sub, PUBLICATION), RDF::Literal.new('http://pubs.example.org/1')
  end

  private

  def fixer(**options)
    SubmissionDatatypeFixer.new(logger: Logger.new(StringIO.new), **options)
  end

  def create(acronym, submission_count:)
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: submission_count, process_submission: false, acronym: acronym,
      file_path: File.expand_path('data/ontology_files/BRO_v3.2.owl', __dir__)
    )
  end

  def submissions(acronym)
    ont = LinkedData::Models::Ontology.find(acronym).include(:submissions).first
    ont.submissions.each { |s| s.bring(:submissionId) }
    ont.submissions.sort_by(&:submissionId)
  end

  def store(sub, predicate, *objects)
    graph = RDF::Graph.new
    objects.each { |o| graph << [sub.id, predicate, o] }
    Goo.sparql_update_client.insert_data(graph, graph: sub.graph)
  end

  def clear(sub, predicate)
    Goo.sparql_update_client.update(<<~SPARQL)
      DELETE { GRAPH <#{sub.graph}> { <#{sub.id}> <#{predicate}> ?o . } }
      WHERE { GRAPH <#{sub.graph}> { <#{sub.id}> <#{predicate}> ?o . } }
    SPARQL
  end

  def stored(sub, predicate)
    query = "SELECT ?o FROM <#{sub.graph}> WHERE { <#{sub.id}> <#{predicate}> ?o . }"
    Goo.sparql_query_client.query(query).map { |s| s[:o] }
  end
end
