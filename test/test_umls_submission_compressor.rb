require_relative 'test_case'
require 'tmpdir'

class TestUmlsSubmissionCompressor < TestCase
  SAMPLE_TTL = (1..2000).map { |i| "<http://purl.bioontology.org/ontology/TST/C#{i}> a owl:Class .\n" }.join
  Compressor = NcboCron::Models::UmlsSubmissionCompressor

  def test_gzip_file_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sample.ttl')
      File.write(path, SAMPLE_TTL)
      gz_path = Compressor.gzip_file(path)

      assert_equal "#{path}.gz", gz_path
      assert File.exist?(path), 'gzip_file must keep the original'
      Zlib::GzipReader.open(gz_path) do |gz|
        assert_equal 'sample.ttl', gz.orig_name
        assert_equal SAMPLE_TTL, gz.read
      end
    end
  end

  def test_gzip_file_removes_output_when_verification_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sample.ttl')
      File.write(path, SAMPLE_TTL)
      Compressor.stubs(:gunzip_digest).returns('mismatch')

      assert_raises(Compressor::VerificationError) { Compressor.gzip_file(path) }
      assert_equal ['sample.ttl'], Dir.children(dir)
    end
  ensure
    Compressor.unstub(:gunzip_digest)
  end
end
