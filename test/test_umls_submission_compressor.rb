require_relative 'test_case'
require 'redis'
require 'zlib'

class TestUmlsSubmissionCompressor < TestCase
  TURTLE = <<~TTL.freeze
    @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
    <http://purl.bioontology.org/ontology/TEST/C1> skos:prefLabel "Concept one"@en .
    <http://purl.bioontology.org/ontology/TEST/C2> skos:prefLabel "Concept two"@en .
  TTL

  def before_all
    super
    @@redis = Redis.new(host: NcboCron.settings.redis_host, port: NcboCron.settings.redis_port)
  end

  def setup
    super
    @@redis.del(NcboCron::Helpers::OntologyHelper::PROCESS_QUEUE_HOLDER)
    @tmp = Dir.mktmpdir('umls-compress-')
    turtle_path = File.join(@tmp, 'UMLSZIP.ttl')
    File.write(turtle_path, TURTLE * 50)

    create(acronym: 'UMLSZIP', format: 'UMLS', submission_count: 2, file_path: turtle_path)
    create(acronym: 'OWLKEEP', format: 'OWL', submission_count: 1,
           file_path: File.expand_path('data/ontology_files/BRO_v3.2.owl', __dir__))
  end

  def teardown
    @@redis.del(NcboCron::Helpers::OntologyHelper::PROCESS_QUEUE_HOLDER)
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    FileUtils.rm_rf(@tmp)
    super
  end

  def test_compresses_umls_submissions_and_points_them_at_the_archive
    originals = submissions('UMLSZIP-0').map { |s| s.uploadFilePath.to_s }
    owl_path = submissions('OWLKEEP-0').first.uploadFilePath.to_s

    results = compressor.run

    assert_equal [:compressed, :compressed], results.map(&:status), results.join("\n")
    submissions('UMLSZIP-0').each_with_index do |sub, i|
      assert_equal "#{originals[i]}.gz", sub.uploadFilePath.to_s
      assert_equal 'UMLSZIP.ttl', sub.masterFileName
      assert sub.zipped?
      refute File.exist?(originals[i]), 'the uncompressed original is deleted'
      assert_equal TURTLE * 50, Zlib::GzipReader.open(sub.uploadFilePath.to_s, &:read)
      sub.bring_remaining
      assert sub.valid?, sub.errors.inspect
    end
    assert_equal owl_path, submissions('OWLKEEP-0').first.uploadFilePath.to_s, 'non-UMLS submissions are left alone'
    assert File.exist?(owl_path)
  end

  def test_a_compressed_submission_extracts_to_its_master_file
    compressor.run
    sub = submissions('UMLSZIP-0').last
    sub.bring_remaining

    sub.unzip_submission(Logger.new(StringIO.new))

    assert_equal File.join(sub.zip_folder, 'UMLSZIP.ttl'), sub.master_file_path
    assert_equal TURTLE * 50, File.read(sub.master_file_path)
  end

  def test_rerun_leaves_compressed_submissions_alone
    compressor.run
    results = compressor.run
    assert_equal [:already_compressed, :already_compressed], results.map(&:status)
  end

  def test_dry_run_changes_nothing
    originals = submissions('UMLSZIP-0').map { |s| s.uploadFilePath.to_s }

    results = compressor(dry_run: true).run

    assert_equal [:would_compress, :would_compress], results.map(&:status)
    assert_equal originals, submissions('UMLSZIP-0').map { |s| s.uploadFilePath.to_s }
    originals.each do |path|
      assert File.exist?(path)
      refute File.exist?("#{path}.gz")
    end
  end

  def test_keep_original
    original = submissions('UMLSZIP-0').first.uploadFilePath.to_s
    compressor(keep_original: true).run
    assert File.exist?(original)
    assert_equal "#{original}.gz", submissions('UMLSZIP-0').first.uploadFilePath.to_s
  end

  def test_only_named_ontologies_are_compressed
    other_turtle = File.join(@tmp, 'UMLSOTHER.ttl')
    File.write(other_turtle, TURTLE)
    create(acronym: 'UMLSOTHER', format: 'UMLS', submission_count: 1, file_path: other_turtle)

    results = compressor.run(acronyms: ['umlsother-0'])

    assert_equal [['UMLSOTHER-0', :compressed]], results.map { |r| [r.acronym, r.status] }
    refute submissions('UMLSZIP-0').any?(&:zipped?)
  end

  def test_queued_submission_is_skipped
    queued = submissions('UMLSZIP-0').first
    NcboCron::Helpers::OntologyHelper.queue_submission(queued)

    results = compressor.run

    assert_equal [:queued, :compressed], results.map(&:status)
    refute submissions('UMLSZIP-0').first.zipped?
  end

  def test_missing_file_is_reported
    sub = submissions('UMLSZIP-0').first
    File.delete(sub.uploadFilePath.to_s)

    c = compressor
    results = c.run

    assert_equal [:missing, :compressed], results.map(&:status)
    assert_equal 1, c.failures.length
  end

  def test_invalid_submission_keeps_its_original_file
    original = submissions('UMLSZIP-0').first.uploadFilePath.to_s
    LinkedData::Models::OntologySubmission.any_instance.stubs(:valid?).returns(false)

    results = compressor.run

    assert_equal [:invalid, :invalid], results.map(&:status)
    LinkedData::Models::OntologySubmission.any_instance.unstub(:valid?)
    assert_equal original, submissions('UMLSZIP-0').first.uploadFilePath.to_s
    assert File.exist?(original)
    refute File.exist?("#{original}.gz"), 'the archive of a submission that was not repointed is removed'
  end

  private

  def compressor(**options)
    NcboCron::Models::UmlsSubmissionCompressor.new(logger: Logger.new(StringIO.new), **options)
  end

  def create(acronym:, format:, submission_count:, file_path:)
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: submission_count, process_submission: false,
      acronym: acronym, ontology_format: format, file_path: file_path
    )
  end

  def submissions(acronym)
    ont = LinkedData::Models::Ontology.find(acronym).include(:submissions).first
    ont.submissions.each { |s| s.bring(:submissionId, :uploadFilePath, :masterFileName) }
    ont.submissions.sort_by(&:submissionId)
  end
end
