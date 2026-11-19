require_relative 'test_case'

class TestOrphanedSubmissionsReport < TestCase
  Report = NcboCron::Models::OrphanedSubmissionsReport
  Submission = LinkedData::Models::OntologySubmission
  ONTOLOGY = Submission.attribute_uri(:ontology)
  SUBMISSION_ID = Submission.attribute_uri(:submissionId)
  UPLOAD_FILE_PATH = Submission.attribute_uri(:uploadFilePath)
  LEGACY_HOMEPAGE = RDF::URI.new("#{Goo.namespaces[:metadata]}homepage")

  def setup
    super
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: 3, process_submission: false, acronym: 'ORPHAN',
      file_path: File.expand_path('data/ontology_files/BRO_v3.2.owl', __dir__)
    )
    @ont = LinkedData::Models::Ontology.find('ORPHAN-0').first
    @prefix = @ont.id.to_s
  end

  def teardown
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    # Ontology#delete only reaches linked submissions, so the orphans these tests make stay behind
    Goo.sparql_data_client.delete_graph(Submission.uri_type)
    Goo.sparql_data_client.delete_graph(LinkedData::Models::Metric.uri_type)
    super
  end

  def test_clean_data_has_no_orphans
    result = report.run

    assert_empty result.orphans
    assert_empty result.orphaned_metrics
    assert_equal 3, result.typed_count
    assert_equal 3, result.linked_count
  end

  def test_unlinked_submission_holding_the_next_id_blocks_the_ontology
    clear(submission_uri(3), ONTOLOGY)

    orphan = only_orphan(report.run)

    assert_equal ['ORPHAN-0', '3', :unlinked, :blocks_next_submission, true, 2],
                 [orphan.acronym, orphan.submission_id, orphan.kind, orphan.effect,
                  orphan.ontology_exists, orphan.highest_linked_id]
    assert_includes orphan.statuses, 'UPLOADED'
    refute_empty orphan.upload_file_paths

    # The reason it blocks: the next id is the orphan's, and Goo rejects it as a duplicate.
    # Built the way OntologyHelper.create_submission builds a pulled submission.
    ont = LinkedData::Models::Ontology.find('ORPHAN-0').first
    assert_equal 3, ont.next_submission_id
    previous = Submission.find(submission_uri(2)).first
    previous.bring_remaining
    new_sub = Submission.new
    previous.loaded_attributes.each { |attr| new_sub.send("#{attr}=", previous.send(attr)) }
    new_sub.submissionId = ont.next_submission_id
    refute new_sub.valid?
    assert_match(/already a persistent resource/, new_sub.errors.to_s)
  end

  def test_unlinked_submission_below_the_highest_id_has_no_effect
    clear(submission_uri(1), ONTOLOGY)

    orphan = only_orphan(report.run)

    assert_equal [:unlinked, :none, 3], [orphan.kind, orphan.effect, orphan.highest_linked_id]
  end

  def test_unlinked_submission_above_the_next_id_blocks_later
    insert(RDF::URI.new("#{@prefix}/submissions/7"), RDF.type, Submission.uri_type)
    insert(RDF::URI.new("#{@prefix}/submissions/7"), SUBMISSION_ID, RDF::Literal.new(7))

    orphan = only_orphan(report.run)

    assert_equal ['7', :unlinked, :blocks_later], [orphan.submission_id, orphan.kind, orphan.effect]
    assert_equal 2, orphan.triples.length
  end

  def test_link_to_a_missing_ontology_is_dangling
    clear(submission_uri(2), ONTOLOGY)
    insert(submission_uri(2), ONTOLOGY, RDF::URI.new('http://data.bioontology.org/ontologies/GONE'))

    orphan = only_orphan(report.run)

    assert_equal [:dangling, :ontology_deleted, false], [orphan.kind, orphan.effect, orphan.ontology_exists]
  end

  def test_untyped_fragment_above_the_highest_id_merges_into_the_next_submission
    fragment = RDF::URI.new("#{@prefix}/submissions/4")
    insert(fragment, LEGACY_HOMEPAGE, RDF::Literal.new('http://homepage.example.org'))
    insert(fragment, UPLOAD_FILE_PATH, RDF::Literal.new('/no/such/file.owl'))

    orphan = only_orphan(report.run)

    assert_equal ['4', :untyped, :merges_into_new, 3], [orphan.submission_id, orphan.kind, orphan.effect,
                                                        orphan.highest_linked_id]
    assert_equal [['/no/such/file.owl', false]], orphan.upload_files
    refute orphan.folder_exists
  end

  def test_fragment_of_a_deleted_ontology_and_its_metrics_are_reported
    gone = RDF::URI.new('http://data.bioontology.org/ontologies/GONE/submissions/1')
    insert(gone, SUBMISSION_ID, RDF::Literal.new(1))
    metrics = RDF::URI.new("#{gone}/metrics")
    graph = RDF::Graph.new << [metrics, RDF.type, LinkedData::Models::Metric.uri_type]
    Goo.sparql_update_client.insert_data(graph, graph: LinkedData::Models::Metric.uri_type)

    result = report.run
    orphan = only_orphan(result)

    assert_equal ['GONE', :untyped, :ontology_deleted], [orphan.acronym, orphan.kind, orphan.effect]
    assert_equal [metrics.to_s], result.orphaned_metrics
  end

  def test_only_named_ontologies_are_reported
    clear(submission_uri(3), ONTOLOGY)
    insert(RDF::URI.new('http://data.bioontology.org/ontologies/GONE/submissions/1'), SUBMISSION_ID,
           RDF::Literal.new(1))

    assert_equal ['GONE'], report.run(acronyms: ['gone']).orphans.map(&:acronym)
    assert_equal ['ORPHAN-0'], report.run(acronyms: ['ORPHAN-0']).orphans.map(&:acronym)
  end

  def test_small_pages_give_the_same_result
    clear(submission_uri(3), ONTOLOGY)
    insert(RDF::URI.new("#{@prefix}/submissions/5"), LEGACY_HOMEPAGE, RDF::Literal.new('http://h.example.org'))

    paged = report(page_size: 2).run

    assert_equal report.run.orphans.map(&:id), paged.orphans.map(&:id)
    assert_equal 2, paged.orphans.length
    assert_equal 3, paged.typed_count
  end

  def test_report_changes_nothing
    clear(submission_uri(3), ONTOLOGY)
    before = triple_count

    report.run

    assert_equal before, triple_count
  end

  def test_api_keys_are_masked
    assert_equal 'http://x.example.org/dl?apikey=***&format=owl',
                 Report.mask('http://x.example.org/dl?apikey=8b5b7825-secret&format=owl')
  end

  private

  def report(**options)
    Report.new(logger: Logger.new(StringIO.new), **options)
  end

  def only_orphan(result)
    assert_equal 1, result.orphans.length, result.orphans.join("\n")
    result.orphans.first
  end

  def submission_uri(id)
    RDF::URI.new("#{@prefix}/submissions/#{id}")
  end

  def insert(subject, predicate, object)
    graph = RDF::Graph.new << [subject, predicate, object]
    Goo.sparql_update_client.insert_data(graph, graph: Submission.uri_type)
  end

  def clear(subject, predicate)
    Goo.sparql_update_client.update(<<~SPARQL)
      DELETE { GRAPH <#{Submission.uri_type}> { <#{subject}> <#{predicate}> ?o . } }
      WHERE { GRAPH <#{Submission.uri_type}> { <#{subject}> <#{predicate}> ?o . } }
    SPARQL
  end

  def triple_count
    query = 'SELECT (COUNT(*) AS ?c) WHERE { GRAPH ?g { ?s ?p ?o } }'
    Goo.sparql_query_client.query(query).first[:c].to_i
  end
end
