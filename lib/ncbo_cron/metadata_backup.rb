require 'logger'
require 'json'
require 'net/http'
require 'uri'
require 'zlib'
require 'tempfile'
require 'fileutils'
require 'digest'
require 'time'
require 'set'
require 'rdf'

module NcboCron
  # Backend-agnostic export/restore of the triplestore "metadata" graphs: the
  # graphs Goo models write to directly (Ontology, OntologySubmission, User,
  # Note, Project, RestBackupMapping, ...). Per-submission content graphs are
  # not included; they are rebuilt by reprocessing the ontology files.
  #
  # The graph list comes from the Goo model registry, so it follows the
  # installed ontologies_linked_data version instead of a hand-kept list.
  #
  # Output is one gzipped N-Quads file plus a JSON manifest with per-graph
  # triple counts. N-Quads loads directly into AllegroGraph (agtool load),
  # GraphDB and Virtuoso, and MetadataRestore loads it into any Goo backend.
  #
  # Statements are handled as N-Triples/N-Quads lines rather than through
  # RDF.rb's readers: rdf 3.3.4 treats any line containing "VERSION" (even
  # inside a literal) as an RDF 1.2 version directive and fails to parse it.
  module MetadataBackup
    SUBMISSION_GRAPH = %r{/ontologies/[^/]+/submissions/\d+\z}.freeze
    # Characters N-Triples/SPARQL do not allow unescaped in an IRI. A dump with
    # these loads into some stores and is rejected by others.
    BAD_IRI_CHARS = /[\x00-\x20<>"{}|^`\\]/.freeze
    # N-Triples terms. IRIs exclude whitespace and quotes so that a literal
    # ending in something like `<a href=` is not mistaken for an IRI.
    IRI = /<[^<>"\s]*>/.source
    BNODE = /_:[^\s.]+(?:\.[^\s.]+)*/.source
    LITERAL = /"(?:[^"\\]|\\.)*"(?:@[a-zA-Z]+(?:-[a-zA-Z0-9]+)*|\^\^#{IRI})?/.source
    STATEMENT = /(#{IRI}|#{BNODE})\s+(#{IRI})\s+(#{IRI}|#{BNODE}|#{LITERAL})/.source
    # One N-Triples line: subject, predicate, object.
    TRIPLE = /\A#{STATEMENT}\s*\.\z/.freeze
    # One N-Quads line: the triple and its graph IRI.
    QUAD = /\A(#{STATEMENT})\s+<([^<>"\s]*)>\s*\.\z/.freeze

    # Registered Goo models whose graph never holds data.
    # OntologyProperty is only the shared base of the Annotation/Object/
    # DatatypeProperty models, which live in submission graphs.
    EXCLUDED_MODELS = %w[LinkedData::Models::OntologyProperty].freeze

    class Error < StandardError; end

    # Graphs of every Goo model that stores its instances in a fixed graph
    # (its rdf:type URI). Models stored per submission (`collection:`) are
    # skipped; their data comes back when the submission is reprocessed.
    def self.model_graphs
      Goo.models.values.uniq.filter_map do |model|
        next if EXCLUDED_MODELS.include?(model.name)
        next if model.collection_opts
        next if model.model_settings[:rdf_type] # type computed per instance

        model.type_uri.to_s
      end.uniq.sort
    end

    # Plain HTTP access to the query endpoint. Goo's query client caches in
    # Redis and parses whole result sets into memory; neither suits a backup.
    class Sparql
      attr_reader :url

      def initialize(url = Goo.sparql_query_client.url.to_s, backend: Goo.sparql_backend_name.to_s)
        @url = URI(url.to_s)
        @fourstore = backend.casecmp?('4store')
      end

      def select(query)
        body = +''
        post(query, 'application/sparql-results+json') { |chunk| body << chunk }
        JSON.parse(body).dig('results', 'bindings')
      end

      # Distinct triples in the graph. Stores can hold exact duplicate triples
      # (both 4store and AllegroGraph do), which COUNT(*) includes but CONSTRUCT
      # returns once. 4store has no sub-selects, so there the distinct rows are
      # streamed and counted instead.
      def count(graph)
        distinct = "SELECT DISTINCT ?s ?p ?o WHERE { GRAPH <#{graph}> { ?s ?p ?o } }"
        return count_rows(distinct) if @fourstore

        rows = select("SELECT (COUNT(*) AS ?c) WHERE { #{distinct} }")
        rows.first ? rows.first['c']['value'].to_i : 0
      end

      # Not ASK: 4store answers true for any GRAPH pattern, even a missing graph.
      def any?(graph)
        select("SELECT ?s WHERE { GRAPH <#{graph}> { ?s ?p ?o } } LIMIT 1").any?
      end

      def graphs
        select('SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }').map { |r| r['g']['value'] }
      end

      # Streams the graph as N-Triples into io. Returns the response Content-Type.
      def construct_graph(graph, io)
        query = "CONSTRUCT { ?s ?p ?o } WHERE { GRAPH <#{graph}> { ?s ?p ?o } }"
        post(query, 'application/n-triples, text/plain;q=0.9') { |chunk| io.write(chunk) }
      end

      private

      # Rows in a TSV result, which escapes newlines inside values. Skips the
      # header and any "#" warning lines 4store adds.
      def count_rows(query)
        rows = -1
        pending = +''
        post(query, 'text/tab-separated-values') do |chunk|
          pending << chunk
          *lines, pending = pending.split("\n", -1)
          rows += lines.count { |l| !l.empty? && !l.start_with?('#') }
        end
        rows += 1 unless pending.empty? || pending.start_with?('#')
        [rows, 0].max
      end

      def post(query, accept)
        req = Net::HTTP::Post.new(@url.request_uri)
        req['Accept'] = accept
        form = { 'query' => query }
        # Without this 4store silently truncates results at its soft limit.
        form['soft-limit'] = '-1' if @fourstore
        req.set_form_data(form)
        req.basic_auth(URI.decode_www_form_component(@url.user), URI.decode_www_form_component(@url.password.to_s)) if @url.user

        http = Net::HTTP.new(@url.host, @url.port)
        http.use_ssl = @url.scheme == 'https'
        http.read_timeout = nil
        content_type = nil
        http.start do
          http.request(req) do |res|
            unless res.is_a?(Net::HTTPSuccess)
              raise Error, "SPARQL endpoint #{@url} returned HTTP #{res.code}: #{res.body.to_s[0, 500]}"
            end

            content_type = res['Content-Type']
            res.read_body { |chunk| yield chunk }
          end
        end
        content_type
      end
    end

    class Exporter
      # errors: the dump does not match the store (exit non-zero)
      # warnings: data that is in the dump but may not load everywhere
      Result = Struct.new(:file, :manifest_file, :manifest, :errors, :warnings, keyword_init: true)

      attr_reader :logger

      # graphs:      graph URIs to export (default: MetadataBackup.model_graphs)
      # extra_graphs: added to the default list
      # audit:       also list every graph in the store and report ones that are
      #              neither metadata nor submission graphs (not covered by a
      #              metadata backup + reprocess)
      def initialize(output_dir:, graphs: nil, extra_graphs: [], audit: false,
                     logger: Logger.new($stdout), sparql: Sparql.new)
        @output_dir = output_dir
        @graphs = (graphs || MetadataBackup.model_graphs) | extra_graphs
        @audit = audit
        @logger = logger
        @sparql = sparql
      end

      def run
        raise Error, "output directory #{@output_dir} does not exist" unless File.directory?(@output_dir)

        stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
        base = File.join(@output_dir, "metadata-#{stamp}")
        file = "#{base}.nq.gz"
        manifest_file = "#{base}.manifest.json"
        partial = "#{file}.partial"
        errors = []
        warnings = []
        graph_stats = {}
        started = Time.now

        logger.info("Exporting #{@graphs.size} metadata graphs from #{@sparql.url} to #{file}")
        File.open(partial, 'wb') do |raw|
          gz = Zlib::GzipWriter.new(raw)
          @graphs.each do |graph|
            stats = export_graph(graph, gz)
            graph_stats[graph] = stats
            errors.concat(stats.delete(:errors))
            warnings.concat(stats.delete(:warnings))
          end
          gz.finish
        end
        File.rename(partial, file)

        manifest = {
          created_at: Time.now.utc.iso8601,
          duration_seconds: (Time.now - started).round(1),
          endpoint: redact(@sparql.url),
          backend: Goo.sparql_backend_name.to_s,
          ontologies_linked_data: gem_version('ontologies_linked_data'),
          goo: gem_version('goo'),
          file: File.basename(file),
          sha256: Digest::SHA256.file(file).hexdigest,
          triples: graph_stats.values.sum { |s| s[:triples] },
          graphs: graph_stats
        }
        manifest[:unlisted_graphs] = audit_graphs if @audit
        manifest[:warnings] = warnings unless warnings.empty?
        manifest[:errors] = errors unless errors.empty?
        File.write(manifest_file, JSON.pretty_generate(manifest))

        logger.info("Wrote #{manifest[:triples]} triples in #{manifest[:duration_seconds]}s (#{File.size(file)} bytes)")
        warnings.each { |w| logger.warn(w) }
        errors.each { |e| logger.error(e) }
        Result.new(file: file, manifest_file: manifest_file, manifest: manifest, errors: errors, warnings: warnings)
      rescue StandardError
        FileUtils.rm_f(partial) if partial
        raise
      end

      private

      # Fetches the graph into a temp file and checks it against a COUNT before
      # anything reaches the dump, so a retry never leaves duplicates behind.
      def export_graph(graph, out)
        Tempfile.create(['graph', '.nt'], binmode: true) do |tmp|
          expected, stats = nil
          2.times do |attempt|
            tmp.truncate(0)
            tmp.rewind
            expected = @sparql.count(graph)
            check_content_type(@sparql.construct_graph(graph, tmp))
            tmp.flush
            stats = scan(tmp)
            break if stats[:triples] == expected

            # A write landing between COUNT and CONSTRUCT shifts the numbers.
            logger.warn("#{graph}: counted #{expected}, fetched #{stats[:triples]}; retrying") if attempt.zero?
          end

          suffix = " <#{graph}> .\n"
          each_triple(tmp) { |s, p, o| out.write("#{s} #{p} #{o}#{suffix}") }

          errors = []
          if stats[:triples] != expected
            errors << "#{graph}: endpoint reports #{expected} triples but #{stats[:triples]} were exported"
          end
          unless stats[:malformed].empty?
            errors << "#{graph}: #{stats[:malformed].size} lines are not N-Triples and were skipped, " \
                      "e.g. #{stats[:malformed].first[0, 200]}"
          end
          warnings = []
          if stats[:bnodes].positive?
            warnings << "#{graph}: #{stats[:bnodes]} triples use blank nodes, which do not survive a restore intact"
          end
          if stats[:bad_iri_count].positive?
            warnings << "#{graph}: #{stats[:bad_iri_count]} triples have IRIs with characters SPARQL and " \
                        "N-Triples forbid; a restore will skip them. E.g. #{stats[:bad_iris].first(3).join('; ')}"
          end
          logger.info("#{graph}: #{stats[:triples]} triples")
          { triples: stats[:triples], errors: errors, warnings: warnings }
        end
      end

      def each_triple(io, malformed = nil)
        io.rewind
        io.each_line do |line|
          line = line.force_encoding(Encoding::UTF_8).strip
          next if line.empty? || line.start_with?('#')

          if (m = TRIPLE.match(line))
            yield m[1], m[2], m[3]
          elsif malformed
            malformed << line
          end
        end
      end

      def scan(io)
        stats = { triples: 0, bnodes: 0, bad_iri_count: 0, bad_iris: [], malformed: [] }
        each_triple(io, stats[:malformed]) do |s, p, o|
          stats[:triples] += 1
          stats[:bnodes] += 1 if s.start_with?('_:') || o.start_with?('_:')
          bad = [s, p, o].find { |t| t.start_with?('<') && unescape(t[1..-2]).match?(BAD_IRI_CHARS) }
          next unless bad

          stats[:bad_iri_count] += 1
          stats[:bad_iris] << "#{s} -> #{bad}" if stats[:bad_iris].size < 20
        end
        stats
      end

      # 4store writes characters such as spaces in IRIs as \\u0020 escapes.
      def unescape(iri)
        iri.gsub(/\\u(\h{4})|\\U(\h{8})/) { [(Regexp.last_match(1) || Regexp.last_match(2)).hex].pack('U') }
      end

      def check_content_type(content_type)
        mime = content_type.to_s.split(';').first.to_s.strip.downcase
        return if mime.empty? || %w[application/n-triples text/plain].include?(mime)

        raise Error, "endpoint answered CONSTRUCT with #{mime} instead of N-Triples"
      end

      def audit_graphs
        known = @graphs.to_set
        @sparql.graphs.reject { |g| known.include?(g) || g.match?(SUBMISSION_GRAPH) }.sort.tap do |extra|
          if extra.any?
            logger.warn("#{extra.size} graphs are neither metadata nor submission graphs and are NOT in this backup:")
            extra.first(50).each { |g| logger.warn("  #{g}") }
          end
        end
      end

      def gem_version(name)
        spec = Gem.loaded_specs[name] or return nil
        ref = spec.source.respond_to?(:revision) ? spec.source.revision : nil
        [spec.version.to_s, ref].compact.join(' ')
      end

      def redact(url)
        u = url.dup
        u.password = 'xxx' if u.password
        u.to_s
      end
    end

    class Restorer
      Result = Struct.new(:graphs, :errors, keyword_init: true)

      attr_reader :logger

      # file:      a metadata-*.nq.gz written by Exporter (plain .nq works too)
      # graphs:    restore only these graph URIs (default: everything in the file)
      # replace:   drop each target graph before loading it; without this the
      #            restore refuses to touch graphs that already hold data
      # dry_run:   parse the file and report counts without writing anything
      def initialize(file:, graphs: nil, replace: false, dry_run: false, batch_size: 1000,
                     logger: Logger.new($stdout), sparql: Sparql.new)
        @file = file
        @only = graphs&.to_set
        @replace = replace
        @dry_run = dry_run
        @batch_size = batch_size
        @logger = logger
        @sparql = sparql
      end

      def run
        expected = expected_counts
        targets = expected.keys
        targets &= @only.to_a if @only
        raise Error, "no graphs to restore from #{@file}" if targets.empty?

        unless @dry_run
          occupied = targets.select { |g| @sparql.any?(g) }
          if occupied.any? && !@replace
            raise Error, "#{occupied.size} target graphs already contain data (e.g. #{occupied.first}); " \
                         'pass --replace to drop and reload them'
          end
          targets.each { |g| Goo.sparql_data_client.delete_graph(RDF::URI(g)) } if @replace
        end

        errors = []
        loaded = Hash.new(0)
        batch = []
        current = nil
        flush = lambda do
          next if batch.empty?

          loaded[current] += insert(current, batch, errors)
          batch = []
        end

        malformed = 0
        each_quad(-> { malformed += 1 }) do |triple, g|
          next unless targets.include?(g)

          if g != current
            flush.call
            current = g
          end
          batch << triple
          flush.call if batch.size >= @batch_size
        end
        flush.call
        errors << "#{malformed} lines in #{@file} are not N-Quads and were skipped" if malformed.positive?

        summary = targets.to_h do |g|
          actual = @dry_run ? loaded[g] : @sparql.count(g)
          errors << "#{g}: expected #{expected[g]} triples, store now has #{actual}" if actual != expected[g]
          logger.info("#{g}: #{actual}/#{expected[g]} triples#{' (dry run)' if @dry_run}")
          [g, { expected: expected[g], restored: actual }]
        end
        errors.each { |e| logger.error(e) }
        Result.new(graphs: summary, errors: errors)
      end

      private

      # Per-graph counts from the manifest next to the dump, or by reading the dump.
      def expected_counts
        manifest = @file.sub(/\.nq(\.gz)?\z/, '.manifest.json')
        if manifest != @file && File.exist?(manifest)
          JSON.parse(File.read(manifest))['graphs'].transform_values { |s| s['triples'] }
        else
          counts = Hash.new(0)
          each_quad { |_triple, graph| counts[graph] += 1 }
          counts
        end
      end

      # Yields each statement as [N-Triples text without the final ".", graph IRI].
      def each_quad(on_malformed = nil)
        File.open(@file, 'rb') do |raw|
          io = @file.end_with?('.gz') ? Zlib::GzipReader.new(raw) : raw
          io.each_line do |line|
            line = line.force_encoding(Encoding::UTF_8).strip
            next if line.empty? || line.start_with?('#')

            if (m = QUAD.match(line))
              yield m[1], m[5]
            elsif on_malformed
              on_malformed.call
            end
          end
        end
      end

      # A SPARQL UPDATE string that also carries the graph it writes, which
      # Goo's client needs to invalidate its query cache for that graph.
      InsertData = Struct.new(:graph, :triples) do
        def options = { graph: graph }
        def to_s = "INSERT DATA { GRAPH <#{graph}> {\n#{triples.map { |t| "#{t} ." }.join("\n")}\n} }"
      end

      # Loads through SPARQL UPDATE (INSERT DATA), the same path Goo uses to save
      # models, so it behaves the same on every backend. N-Triples terms are
      # valid SPARQL, so lines are sent as they appear in the dump. A failing
      # batch is split until the offending triples are isolated; the rest load.
      def insert(graph, triples, errors)
        return triples.size if @dry_run

        Goo.sparql_update_client.update(InsertData.new(graph, triples))
        triples.size
      rescue StandardError => e
        if triples.size == 1
          errors << "#{graph}: could not load #{triples.first[0, 300]}: #{e.message[0, 200]}"
          return 0
        end
        half = triples.size / 2
        insert(graph, triples[0...half], errors) + insert(graph, triples[half..], errors)
      end
    end
  end
end
