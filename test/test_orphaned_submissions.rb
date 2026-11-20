require_relative 'test_case'
require 'open3'

# The report is a standalone script; load it without running its command line
load File.expand_path('../bin/ncbo_orphaned_submissions', __dir__)

class TestOrphanedSubmissionsReport < TestCase
  Report = OrphanedSubmissionsReport
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
    assert_empty result.other_subjects
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

    # It belongs to the ontology its URI names, which still exists; id 2 is below the highest (3)
    assert_equal [:dangling, :none, true, ['http://data.bioontology.org/ontologies/GONE']],
                 [orphan.kind, orphan.effect, orphan.ontology_exists, orphan.linked_to]
  end

  def test_dangling_submission_holding_the_next_id_blocks_the_ontology
    clear(submission_uri(3), ONTOLOGY)
    insert(submission_uri(3), ONTOLOGY, RDF::URI.new('http://data.bioontology.org/ontologies/GONE'))

    orphan = only_orphan(report.run)

    assert_equal ['ORPHAN-0', :dangling, :blocks_next_submission, 2],
                 [orphan.acronym, orphan.kind, orphan.effect, orphan.highest_linked_id]
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

  def test_fragment_of_a_deleted_ontology_is_reported
    gone = RDF::URI.new('http://data.bioontology.org/ontologies/GONE/submissions/1')
    insert(gone, SUBMISSION_ID, RDF::Literal.new(1))

    orphan = only_orphan(report.run)

    assert_equal ['GONE', :untyped, :ontology_deleted], [orphan.acronym, orphan.kind, orphan.effect]
  end

  def test_subjects_not_named_like_a_submission_are_left_alone
    others = [RDF::URI.new("#{@prefix}/notasubmission"), RDF::URI.new('http://example.org/stray')]
    others.each { |s| insert(s, LEGACY_HOMEPAGE, RDF::Literal.new('http://h.example.org')) }

    result = report.run

    assert_empty result.orphans
    assert_equal others.map(&:to_s).sort, result.other_subjects
  end

  def test_only_numeric_submission_ids_get_a_folder
    insert(RDF::URI.new("#{@prefix}/submissions/latest"), LEGACY_HOMEPAGE, RDF::Literal.new('http://h.example.org'))

    orphan = only_orphan(report.run)

    assert_equal ['latest', :none, nil], [orphan.submission_id, orphan.effect, orphan.folder]
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

class TestOrphanedSubmissionRemover < TestCase
  Submission = LinkedData::Models::OntologySubmission
  ONTOLOGY = Submission.attribute_uri(:ontology)
  SUBMISSION_ID = Submission.attribute_uri(:submissionId)
  LEGACY_HOMEPAGE = RDF::URI.new("#{Goo.namespaces[:metadata]}homepage")
  GONE = 'http://data.bioontology.org/ontologies/GONE/submissions/1'.freeze
  STANDALONE_METRICS = 'http://data.bioontology.org/ontologies/GONE/submissions/9/metrics'.freeze

  def setup
    super
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: 3, process_submission: false, acronym: 'REMOVE',
      file_path: File.expand_path('data/ontology_files/BRO_v3.2.owl', __dir__)
    )
    @ont = LinkedData::Models::Ontology.find('REMOVE-0').first
    @prefix = @ont.id.to_s
    @work = Dir.mktmpdir('remove_orphans')
    @backup = File.join(@work, 'backup.nq')
    @quarantine = File.join(@work, 'quarantine')

    # a blocking orphan: submission 3 loses its ontology link, so the next id is 3 again
    clear(sub_uri(3), ONTOLOGY)
    insert(metrics_uri(sub_uri(3)), RDF.type, LinkedData::Models::Metric.uri_type, graph: metrics_graph)
    # an untyped fragment above the highest id, with a folder of its own
    insert(sub_uri(5), LEGACY_HOMEPAGE, RDF::Literal.new('http://homepage.example.org'))
    FileUtils.mkdir_p(File.join(repository, 'REMOVE-0', '5'))
    File.write(File.join(repository, 'REMOVE-0', '5', 'stale.owl'), 'stale')
    # a fragment of a deleted ontology, and a metrics record with no submission at all
    insert(RDF::URI.new(GONE), SUBMISSION_ID, RDF::Literal.new(1))
    insert(RDF::URI.new(STANDALONE_METRICS), RDF.type, LinkedData::Models::Metric.uri_type, graph: metrics_graph)
  end

  def teardown
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    Goo.sparql_data_client.delete_graph(Submission.uri_type)
    Goo.sparql_data_client.delete_graph(metrics_graph)
    FileUtils.rm_rf(@work)
    super
  end

  def test_removes_every_orphan_and_keeps_healthy_submissions
    folder3 = File.join(repository, 'REMOVE-0', '3')
    assert Dir.exist?(folder3), 'the sample data writes a folder for submission 3'

    results = remover.run

    assert_equal %i[removed], results.map(&:status).uniq, results.join("\n")
    assert_empty report.run.orphans
    assert_equal [1, 2], linked_ids
    assert_empty triples_of(metrics_uri(sub_uri(3)), metrics_graph), 'the orphan\'s own metrics go with it'
    refute_empty triples_of(STANDALONE_METRICS, metrics_graph), 'metrics with no submission are out of scope'
    refute Dir.exist?(folder3)
    assert File.exist?(File.join(@quarantine, 'REMOVE-0', '3'))
    assert File.exist?(File.join(@quarantine, 'REMOVE-0', '5', 'stale.owl'))
    assert Dir.exist?(File.join(repository, 'REMOVE-0', '1')), 'healthy folders stay'
  end

  def test_backup_restores_what_was_removed
    before = triple_count

    remover.run
    removed = before - triple_count
    assert_operator removed, :>, 0
    lines = File.readlines(@backup)
    comments = lines.select { |l| l.start_with?('#') }
    assert_equal removed, lines.length - comments.length
    assert_equal 3, comments.length, 'one comment line per removed orphan'
    assert(comments.any? { |c| c.include?(sub_uri(3).to_s) && c.include?(File.join(@quarantine, 'REMOVE-0', '3')) })
    assert_equal '600', format('%o', File.stat(@backup).mode & 0o777)

    graph = RDF::Repository.new
    RDF::NQuads::Reader.open(@backup) { |reader| reader.each_statement { |st| graph << st } }
    graph.each_graph do |g|
      data = RDF::Graph.new
      g.each_statement { |st| data << [st.subject, st.predicate, st.object] }
      Goo.sparql_update_client.insert_data(data, graph: g.graph_name)
    end
    assert_equal before, triple_count
  end

  def test_blocking_only_removes_just_the_blocker_and_unblocks_the_ontology
    results = remover.run(blocking_only: true)

    assert_equal [[sub_uri(3).to_s, :removed]], results.map { |r| [r.id, r.status] }
    assert_equal 1, results.first.metrics_triples
    left = report.run
    assert_equal [sub_uri(5).to_s, GONE].sort, left.orphans.map(&:id).sort

    ont = LinkedData::Models::Ontology.find('REMOVE-0').first
    previous = Submission.find(sub_uri(2)).first
    previous.bring_remaining
    new_sub = Submission.new
    previous.loaded_attributes.each { |attr| new_sub.send("#{attr}=", previous.send(attr)) }
    new_sub.submissionId = ont.next_submission_id
    assert_equal 3, new_sub.submissionId
    assert new_sub.valid?, new_sub.errors.inspect
  end

  def test_only_named_ontologies_are_removed
    results = remover.run(acronyms: ['gone'])

    assert_equal [GONE], results.map(&:id)
    assert_equal [sub_uri(3).to_s, sub_uri(5).to_s], report.run.orphans.map(&:id)
  end

  def test_an_orphan_relinked_since_the_report_is_skipped
    orphans = report.run.orphans
    insert(sub_uri(3), ONTOLOGY, @ont.id)

    results = remover.remove(orphans)

    blocker = results.find { |r| r.id == sub_uri(3).to_s }
    assert_equal :skipped, blocker.status
    assert_match(/now linked/, blocker.message)
    assert_equal [1, 2, 3], linked_ids
  end

  def test_a_failed_delete_moves_the_folder_back
    folder3 = File.join(repository, 'REMOVE-0', '3')
    blocker = report.run.orphans.select { |o| o.id == sub_uri(3).to_s }
    result = with_failing_deletes { remover.remove(blocker).first }

    assert_equal :error, result.status
    assert_match(/store unavailable; folder moved back/, result.message)
    assert Dir.exist?(folder3)
    refute Dir.exist?(File.join(@quarantine, 'REMOVE-0', '3'))
    assert_includes report.run.orphans.map(&:id), sub_uri(3).to_s, 'still there for the next run'
  end

  def test_blank_nodes_leave_the_orphan_untouched
    insert(metrics_uri(sub_uri(3)), LEGACY_HOMEPAGE, RDF::Node.new, graph: metrics_graph)
    before = triple_count
    blocker = report.run.orphans.select { |o| o.id == sub_uri(3).to_s }

    result = remover.remove(blocker).first

    assert_equal :error, result.status
    assert_match(/blank-node/, result.message)
    assert_equal before, triple_count
    assert Dir.exist?(File.join(repository, 'REMOVE-0', '3'))
    assert_empty File.read(@backup)
  end

  def test_a_stop_request_stops_before_the_next_orphan
    r = remover
    r.request_stop

    assert_empty r.run
    assert r.interrupted?
    assert_equal 3, report.run.orphans.length
  end

  def test_an_unwritable_backup_stops_before_anything_changes
    before = triple_count
    r = OrphanedSubmissionRemover.new(logger: quiet, backup: @work, quarantine: @quarantine,
                                      repository_folder: repository)

    assert_raises(Errno::EISDIR) { r.run }
    assert_equal before, triple_count
    assert Dir.exist?(File.join(repository, 'REMOVE-0', '3'))
  end

  def test_a_backup_file_is_required_to_remove
    assert_raises(ArgumentError) { OrphanedSubmissionRemover.new(logger: quiet, backup: nil) }
  end

  def test_command_line_refuses_to_remove_without_a_backup
    out, status = run_script('--remove')
    refute status.success?
    assert_match(/--remove needs --backup/, out)

    out, status = run_script('--blocking-only')
    refute status.success?
    assert_match(/only apply with --remove/, out)
  end

  def test_works_with_the_query_cache_on
    Goo.use_cache = true
    report.run # warm the cache with the orphans

    results = remover.run

    assert_equal %i[removed], results.map(&:status).uniq, results.join("\n")
    assert_empty report.run.orphans, 'cached results must not bring the orphans back'
  ensure
    Goo.use_cache = false
  end

  private

  # The option checks run before config is loaded, so this never touches a triplestore
  def run_script(*args)
    script = File.expand_path('../bin/ncbo_orphaned_submissions', __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, script, *args)
    [out, status]
  end

  def remover
    OrphanedSubmissionRemover.new(logger: quiet, backup: @backup, quarantine: @quarantine,
                                  repository_folder: repository)
  end

  def report
    OrphanedSubmissionsReport.new(logger: quiet, repository_folder: repository)
  end

  def quiet
    Logger.new(StringIO.new)
  end

  def repository
    LinkedData.settings.repository_folder
  end

  def metrics_graph
    LinkedData::Models::Metric.uri_type
  end

  def sub_uri(id)
    RDF::URI.new("#{@prefix}/submissions/#{id}")
  end

  def metrics_uri(sub)
    RDF::URI.new("#{sub}/metrics")
  end

  def linked_ids
    LinkedData::Models::Ontology.find('REMOVE-0').include(submissions: :submissionId).first
                                .submissions.map(&:submissionId).sort
  end

  def insert(subject, predicate, object, graph: Submission.uri_type)
    data = RDF::Graph.new << [subject, predicate, object]
    Goo.sparql_update_client.insert_data(data, graph: graph)
  end

  def clear(subject, predicate)
    Goo.sparql_update_client.update(<<~SPARQL)
      DELETE { GRAPH <#{Submission.uri_type}> { <#{subject}> <#{predicate}> ?o . } }
      WHERE { GRAPH <#{Submission.uri_type}> { <#{subject}> <#{predicate}> ?o . } }
    SPARQL
  end

  def triple_count
    Goo.sparql_query_client.query('SELECT (COUNT(*) AS ?c) WHERE { GRAPH ?g { ?s ?p ?o } }').first[:c].to_i
  end

  def triples_of(subject, graph)
    Goo.sparql_query_client.query("SELECT ?p ?o WHERE { GRAPH <#{graph}> { <#{subject}> ?p ?o } }").to_a
  end

  # teardown deletes through the same client, so the stub must be gone before it runs
  def with_failing_deletes
    Goo.sparql_update_client.stubs(:delete_data).raises(RuntimeError, 'store unavailable')
    yield
  ensure
    Goo.sparql_update_client.unstub(:delete_data)
  end
end
