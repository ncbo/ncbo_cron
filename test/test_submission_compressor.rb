require_relative 'test_case'
require 'redis'
require 'zlib'

# The migration is a standalone script; load it without running its command line
load File.expand_path('../bin/migrations/compress_submissions', __dir__)

class TestSubmissionCompressor < TestCase
  TURTLE = <<~TTL.freeze
    @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
    <http://purl.bioontology.org/ontology/TEST/C1> skos:prefLabel "Concept one"@en .
    <http://purl.bioontology.org/ontology/TEST/C2> skos:prefLabel "Concept two"@en .
  TTL

  def before_all
    super
    @@redis = Redis.new(host: NcboCron.settings.redis_host, port: NcboCron.settings.redis_port)
  end

  # GZIPME has three submissions; 1 and 2 are archived, 3 is the latest
  def setup
    super
    @@redis.del(NcboCron::Helpers::OntologyHelper::PROCESS_QUEUE_HOLDER)
    @tmp = Dir.mktmpdir('compress-')
    @turtle_path = File.join(@tmp, 'GZIPME.ttl')
    File.write(@turtle_path, TURTLE * 50)

    @group = LinkedData::Models::Group.find('UMLS').first ||
             LinkedData::Models::Group.new(acronym: 'UMLS', name: 'UMLS').save
    create(acronym: 'GZIPME', format: 'UMLS', submission_count: 3, archived: [1, 2], in_group: true)
    create(acronym: 'OWLKEEP', format: 'OWL', submission_count: 2, archived: [1],
           file_path: File.expand_path('data/ontology_files/BRO_v3.2.owl', __dir__))
  end

  def teardown
    @@redis.del(NcboCron::Helpers::OntologyHelper::PROCESS_QUEUE_HOLDER)
    LinkedData::SampleData::Ontology.delete_ontologies_and_submissions
    LinkedData::Models::Group.find('UMLS').first&.delete
    FileUtils.rm_rf(@tmp)
    super
  end

  def test_compresses_archived_submissions_and_points_them_at_the_archive
    originals = paths('GZIPME-0')

    results = compressor(group: 'UMLS').run

    assert_equal [:compressed, :compressed], results.map(&:status), results.join("\n")
    submissions('GZIPME-0').first(2).each_with_index do |sub, i|
      assert_equal "#{originals[i]}.gz", sub.uploadFilePath.to_s
      assert_equal 'GZIPME.ttl', sub.masterFileName
      assert sub.zipped?
      refute File.exist?(originals[i]), 'the uncompressed original is deleted'
      assert_equal TURTLE * 50, Zlib::GzipReader.open(sub.uploadFilePath.to_s, &:read)
      sub.bring_remaining
      assert sub.valid?, sub.errors.inspect
    end
    assert_equal originals.last, paths('GZIPME-0').last, 'the latest submission is not archived'
  end

  def test_include_unarchived_compresses_the_latest_submission_too
    results = compressor(group: 'UMLS', include_unarchived: true).run
    assert_equal [:compressed] * 3, results.map(&:status)
  end

  def test_without_filters_every_ontology_is_compressed
    results = compressor.run
    assert_equal [['GZIPME-0', 1], ['GZIPME-0', 2], ['OWLKEEP-0', 1]],
                 results.map { |r| [r.acronym, r.submission_id] }
    assert_equal 'BRO_v3.2.owl', submissions('OWLKEEP-0').first.masterFileName
  end

  def test_format_filter
    results = compressor(format: 'OWL').run
    assert_equal [['OWLKEEP-0', :compressed]], results.map { |r| [r.acronym, r.status] }
  end

  def test_missing_format_stops_the_run
    error = assert_raises(ArgumentError) { compressor(format: 'NOSUCHFORMAT').run }
    assert_equal 'Ontology format NOSUCHFORMAT not found', error.message
  end

  def test_ontologies_outside_the_group_are_left_alone
    log = StringIO.new

    results = SubmissionCompressor.new(logger: Logger.new(log), group: 'UMLS').run

    assert_equal ['GZIPME-0'], results.map(&:acronym).uniq
    refute submissions('OWLKEEP-0').any?(&:zipped?)
    assert_includes log.string, 'Skipping 1 ontologies outside the UMLS group: OWLKEEP-0'
    assert_empty compressor(group: 'UMLS').run(acronyms: ['OWLKEEP-0']), 'naming an ontology does not bypass the group'
  end

  def test_missing_group_stops_the_run
    error = assert_raises(ArgumentError) { compressor(group: 'NOSUCHGROUP').run }
    assert_equal 'Group NOSUCHGROUP not found', error.message
    refute submissions('GZIPME-0').any?(&:zipped?)
  end

  def test_only_named_ontologies_are_compressed
    results = compressor.run(acronyms: ['owlkeep-0'])
    assert_equal [['OWLKEEP-0', :compressed]], results.map { |r| [r.acronym, r.status] }
    refute submissions('GZIPME-0').any?(&:zipped?)
  end

  def test_files_below_the_minimum_size_are_left_alone
    big = File.size(submissions('OWLKEEP-0').first.uploadFilePath.to_s)

    results = compressor(min_size: big).run

    assert_equal [:too_small, :too_small, :compressed], results.map(&:status)
    refute submissions('GZIPME-0').any?(&:zipped?)
  end

  def test_a_compressed_submission_extracts_to_its_master_file
    compressor.run
    sub = submissions('GZIPME-0').first
    sub.bring_remaining

    sub.unzip_submission(Logger.new(StringIO.new))

    assert_equal File.join(sub.zip_folder, 'GZIPME.ttl'), sub.master_file_path
    assert_equal TURTLE * 50, File.read(sub.master_file_path)
  end

  def test_rerun_leaves_compressed_submissions_alone
    compressor(group: 'UMLS').run
    results = compressor(group: 'UMLS').run
    assert_equal [:already_compressed, :already_compressed], results.map(&:status)
  end

  def test_dry_run_changes_nothing
    originals = paths('GZIPME-0')

    results = compressor(group: 'UMLS', dry_run: true).run

    assert_equal [:would_compress, :would_compress], results.map(&:status)
    assert_equal originals, paths('GZIPME-0')
    originals.each do |path|
      assert File.exist?(path)
      refute File.exist?("#{path}.gz")
    end
  end

  def test_keep_original
    original = paths('GZIPME-0').first
    compressor(group: 'UMLS', keep_original: true).run
    assert File.exist?(original)
    assert_equal "#{original}.gz", paths('GZIPME-0').first
  end

  def test_submission_without_an_ontology_is_skipped
    orphan = submissions('GZIPME-0').first
    model = LinkedData::Models::OntologySubmission
    ont = LinkedData::Models::Ontology.find('GZIPME-0').first
    triple = "GRAPH <#{model.uri_type}> { <#{orphan.id}> <#{model.attribute_uri(:ontology)}> <#{ont.id}> }"
    Goo.sparql_update_client.update("DELETE DATA { #{triple} }")
    log = StringIO.new

    results = SubmissionCompressor.new(logger: Logger.new(log)).run(acronyms: ['GZIPME-0'])

    assert_equal [['GZIPME-0', 2]], results.map { |r| [r.acronym, r.submission_id] }
    assert_includes log.string, 'Skipping 1 submissions with no ontology or no integer submissionId'
    assert_includes log.string, orphan.id.to_s
    assert File.exist?(orphan.uploadFilePath.to_s)
  ensure
    # Relink it so teardown deletes it with its ontology
    Goo.sparql_update_client.update("INSERT DATA { #{triple} }") if triple
  end

  def test_zip_archive_type
    originals = paths('GZIPME-0')

    results = compressor(group: 'UMLS', archive_type: 'zip').run

    assert_equal [:compressed, :compressed], results.map(&:status), results.join("\n")
    sub = submissions('GZIPME-0').first
    assert_equal "#{originals.first}.zip", sub.uploadFilePath.to_s
    assert LinkedData::Utils::FileHelpers.zip?(sub.uploadFilePath.to_s)
    assert_equal 'GZIPME.ttl', sub.masterFileName
    refute File.exist?(originals.first)

    sub.bring_remaining
    sub.unzip_submission(Logger.new(StringIO.new))
    assert_equal TURTLE * 50, File.read(sub.master_file_path)
  end

  def test_unknown_archive_type_is_rejected
    error = assert_raises(ArgumentError) { compressor(archive_type: 'bz2') }
    assert_equal 'Unknown archive type "bz2"', error.message
  end

  def test_file_outside_the_submission_folder_is_left_alone
    sub = submissions('GZIPME-0').first
    sub.bring_remaining
    sub.uploadFilePath = @turtle_path
    sub.save

    results = compressor(group: 'UMLS').run

    assert_equal [:outside_folder, :compressed], results.map(&:status)
    assert File.exist?(@turtle_path)
    refute File.exist?("#{@turtle_path}.gz")
  end

  def test_queued_submission_is_skipped
    NcboCron::Helpers::OntologyHelper.queue_submission(submissions('GZIPME-0').first)

    results = compressor(group: 'UMLS').run

    assert_equal [:queued, :compressed], results.map(&:status)
    refute submissions('GZIPME-0').first.zipped?
  end

  def test_missing_file_is_reported
    File.delete(paths('GZIPME-0').first)

    c = compressor(group: 'UMLS')
    results = c.run

    assert_equal [:missing, :compressed], results.map(&:status)
    assert_equal 1, c.failures.length
  end

  def test_missing_file_reports_an_archive_left_next_to_it
    original = paths('GZIPME-0').first
    LinkedData::Utils::FileHelpers.zip_file(original)
    File.delete(original)

    result = compressor(group: 'UMLS').run.first

    assert_equal :missing, result.status
    assert_includes result.message, 'found GZIPME.ttl.zip next to it'
  end

  def test_invalid_submission_keeps_its_original_file
    original = paths('GZIPME-0').first
    LinkedData::Models::OntologySubmission.any_instance.stubs(:valid?).returns(false)

    results = compressor(group: 'UMLS').run

    assert_equal [:invalid, :invalid], results.map(&:status)
    LinkedData::Models::OntologySubmission.any_instance.unstub(:valid?)
    assert_equal original, paths('GZIPME-0').first
    assert File.exist?(original)
    refute File.exist?("#{original}.gz"), 'the archive of a submission that was not repointed is removed'
  end

  def test_parse_size
    assert_equal 100, SubmissionCompressor.parse_size('100')
    assert_equal 100 * 1024 * 1024, SubmissionCompressor.parse_size('100MB')
    assert_equal 1536 * 1024 * 1024, SubmissionCompressor.parse_size('1.5g')
    assert_raises(ArgumentError) { SubmissionCompressor.parse_size('lots') }
  end

  private

  def compressor(**options)
    SubmissionCompressor.new(logger: Logger.new(StringIO.new), **options)
  end

  def create(acronym:, format:, submission_count:, archived:, file_path: @turtle_path, in_group: false)
    LinkedData::SampleData::Ontology.create_ontologies_and_submissions(
      ont_count: 1, submission_count: submission_count, process_submission: false,
      acronym: acronym, ontology_format: format, file_path: file_path
    )
    archived_status = LinkedData::Models::SubmissionStatus.find('ARCHIVED').first
    submissions("#{acronym}-0").select { |s| archived.include?(s.submissionId) }.each do |sub|
      sub.bring_remaining
      sub.add_submission_status(archived_status)
      sub.save
    end
    return unless in_group

    ont = LinkedData::Models::Ontology.find("#{acronym}-0").first
    ont.bring_remaining
    ont.group = [@group]
    ont.save
  end

  def submissions(acronym)
    ont = LinkedData::Models::Ontology.find(acronym).include(:submissions).first
    ont.submissions.each { |s| s.bring(:submissionId, :uploadFilePath, :masterFileName) }
    ont.submissions.sort_by(&:submissionId)
  end

  def paths(acronym)
    submissions(acronym).map { |s| s.uploadFilePath.to_s }
  end
end
