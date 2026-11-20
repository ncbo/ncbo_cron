require_relative 'test_case'
require_relative '../lib/ncbo_cron/metadata_backup'

class TestMetadataBackup < TestCase
  MB = NcboCron::MetadataBackup
  FIDELITY_GRAPH = 'http://test.ontoportal.org/metadata-backup/fidelity'.freeze

  def before_all
    super
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 2, submission_count: 1, process_submission: false
    )
    s = RDF::URI('http://test.ontoportal.org/thing/1')
    p = RDF::URI('http://test.ontoportal.org/prop')
    tricky = RDF::Graph.new
    [
      RDF::Literal.new(%(back\\slash "quoted"\nnew line\ttab)),
      RDF::Literal.new('café ünïcødé 日本語 😀'),
      # rdf 3.3.4's N-Triples reader fails on any line containing VERSION
      RDF::Literal.new("ALPHA VERSION\r\n\r\nStarting point"),
      # Literals that look like IRIs or statement ends to a naive line parser
      RDF::Literal.new('We need someone with experience <a href='),
      RDF::Literal.new('see <http://example.org/x> .'),
      RDF::Literal.new('hello', language: :en),
      RDF::Literal.new('2026-11-20T00:00:00Z', datatype: RDF::XSD.dateTime),
      RDF::URI('http://test.ontoportal.org/other')
    ].each { |o| tricky << [s, p, o] }
    Goo.sparql_update_client.insert_data(tricky, graph: RDF::URI(FIDELITY_GRAPH))
    # AllegroGraph stores this a second time; CONSTRUCT and the count must agree
    Goo.sparql_update_client.insert_data(RDF::Graph.new << [s, p, RDF::Literal.new('hello', language: :en)],
                                         graph: RDF::URI(FIDELITY_GRAPH))
  end

  def after_all
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    Goo.sparql_data_client.delete_graph(RDF::URI(FIDELITY_GRAPH))
    super
  end

  def setup
    @dir = Dir.mktmpdir('metadata-backup')
    @logger = Logger.new(File::NULL)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_model_graphs_cover_fixed_graph_models_only
    graphs = MB.model_graphs
    %w[Ontology OntologySubmission User Note Project RestBackupMapping
       MappingProcess OntologyType ProvisionalRelation].each do |name|
      assert_includes graphs, "http://data.bioontology.org/metadata/#{name}"
    end
    refute graphs.any? { |g| g.include?('/submissions/') }
    refute_includes graphs, 'http://data.bioontology.org/metadata/OntologyProperty'
  end

  def test_round_trip
    graphs = MB.model_graphs + [FIDELITY_GRAPH]
    before = graphs.to_h { |g| [g, dump_graph(g)] }

    result = export
    assert_empty result.errors
    assert File.exist?(result.file)
    refute File.exist?("#{result.file}.partial")
    manifest = JSON.parse(File.read(result.manifest_file))
    assert_equal Digest::SHA256.file(result.file).hexdigest, manifest['sha256']
    graphs.each { |g| assert_equal before[g].size, manifest['graphs'][g]['triples'], g }
    assert manifest['graphs']['http://data.bioontology.org/metadata/Ontology']['triples'].positive?

    # Refuses to load over existing data without --replace
    err = assert_raises(MB::Error) { restorer(result.file).run }
    assert_match(/--replace/, err.message)

    # Dry run reads the dump but writes nothing
    graphs.each { |g| Goo.sparql_data_client.delete_graph(RDF::URI(g)) }
    dry = restorer(result.file, dry_run: true).run
    assert_empty dry.errors
    assert_equal 0, MB::Sparql.new.count(FIDELITY_GRAPH)

    restored = restorer(result.file).run
    assert_empty restored.errors
    graphs.each { |g| assert_equal before[g], dump_graph(g), "#{g} differs after restore" }

    ont = LinkedData::Models::Ontology.find('TEST-ONT-0').first
    refute_nil ont
  end

  def test_restore_replace_and_graph_filter
    result = export
    ont_graph = 'http://data.bioontology.org/metadata/Ontology'
    expected = dump_graph(FIDELITY_GRAPH)
    extra = RDF::Graph.new << [RDF::URI('http://x/s'), RDF::URI('http://x/p'), RDF::URI('http://x/o')]
    Goo.sparql_update_client.insert_data(extra, graph: RDF::URI(FIDELITY_GRAPH))
    ont_before = dump_graph(ont_graph)

    restored = restorer(result.file, replace: true, graphs: [FIDELITY_GRAPH]).run
    assert_empty restored.errors
    assert_equal [FIDELITY_GRAPH], restored.graphs.keys
    assert_equal expected, dump_graph(FIDELITY_GRAPH)
    assert_equal ont_before, dump_graph(ont_graph)
  end

  def test_export_reports_count_mismatch
    sparql = MB::Sparql.new
    sparql.stubs(:count).returns(999_999)
    result = MB::Exporter.new(output_dir: @dir, graphs: [FIDELITY_GRAPH], logger: @logger, sparql: sparql).run
    assert_equal 1, result.errors.size
    assert_match(/999999/, result.errors.first)
  end

  def test_audit_lists_unknown_graphs
    result = export(audit: true)
    manifest = JSON.parse(File.read(result.manifest_file))
    assert_includes manifest['unlisted_graphs'], FIDELITY_GRAPH
    refute manifest['unlisted_graphs'].any? { |g| g.match?(MB::SUBMISSION_GRAPH) }
  end

  private

  def export(**opts)
    opts = { extra_graphs: [FIDELITY_GRAPH] }.merge(opts)
    opts.delete(:extra_graphs) if opts[:audit]
    MB::Exporter.new(output_dir: @dir, logger: @logger, **opts).run
  end

  def restorer(file, **opts)
    MB::Restorer.new(file: file, logger: @logger, **opts)
  end

  # Order-independent view of a graph for comparison (the store serialises
  # the same triples the same way before and after a restore)
  def dump_graph(graph)
    io = StringIO.new
    MB::Sparql.new.construct_graph(graph, io)
    # Virtuoso answers an empty CONSTRUCT with a "# Empty NT" comment line
    io.string.force_encoding(Encoding::UTF_8).lines.map(&:strip)
      .reject { |l| l.empty? || l.start_with?('#') }.sort
  end
end
