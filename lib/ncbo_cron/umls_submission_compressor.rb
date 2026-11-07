require 'digest'
require 'fileutils'
require 'zlib'

module NcboCron
  module Models

    class UmlsSubmissionCompressor
      class VerificationError < StandardError; end

      READ_CHUNK = 4 * 1024 * 1024
      GZIP_EXTENSION = '.gz'.freeze
      PARTIAL_SUFFIX = '.partial'.freeze

      # Keeps the original; raises VerificationError if the output does not decompress to the same bytes
      def self.gzip_file(path, level: Zlib::BEST_COMPRESSION)
        path = path.to_s
        gz_path = "#{path}#{GZIP_EXTENSION}"
        partial = "#{gz_path}#{PARTIAL_SUFFIX}"
        source_digest = Digest::SHA256.new

        begin
          File.open(partial, 'wb') do |out|
            gz = Zlib::GzipWriter.new(out, level)
            gz.orig_name = File.basename(path)
            gz.mtime = File.mtime(path)
            File.open(path, 'rb') do |src|
              while (chunk = src.read(READ_CHUNK))
                source_digest.update(chunk)
                gz.write(chunk)
              end
            end
            gz.finish
          end

          unless gunzip_digest(partial) == source_digest.hexdigest
            raise VerificationError, "#{partial} does not decompress to the contents of #{path}"
          end

          File.rename(partial, gz_path)
        rescue StandardError
          FileUtils.rm_f(partial)
          raise
        end
        gz_path
      end

      def self.gunzip_digest(gz_path)
        digest = Digest::SHA256.new
        Zlib::GzipReader.open(gz_path) do |gz|
          while (chunk = gz.read(READ_CHUNK))
            digest.update(chunk)
          end
        end
        digest.hexdigest
      end
    end
  end
end
