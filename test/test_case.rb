# Start simplecov if this is a coverage task or if it is run in the CI pipeline
if ENV['COVERAGE'] == 'true' || ENV['CI'] == 'true'
  require 'simplecov'
  require 'simplecov-cobertura'
  # https://github.com/codecov/ruby-standard-2
  # Generate HTML and Cobertura reports which can be consumed by codecov uploader
  SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new(
    [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::CoberturaFormatter]
  )
  SimpleCov.start do
    add_filter '/test/'
    add_filter 'app.rb'
    add_filter 'init.rb'
    add_filter '/config/'
  end
end

require 'minitest/autorun'
require 'minitest/hooks/test'
require 'mocha/minitest'
require 'webmock/minitest'

WebMock.allow_net_connect!
Minitest.after_run { WebMock.reset! }

require_relative '../lib/ncbo_cron'
require_relative '../config/config.test'

unless ENV['RM_INFO']
  require 'minitest/reporters'
  Minitest::Reporters.use! [Minitest::Reporters::SpecReporter.new]
end

Goo.use_cache = false # Make sure tests don't cache

require 'tmpdir'
require 'fileutils'

# One scratch folder per test process for everything the tests write: the
# ontology repository (uploaded files, parsing.log, owlapi output, metrics,
# diffs), the ontologies report and the annotator dictionary. A fresh folder
# per run means no state leaks in from earlier runs.
#
# The folder is removed after a passing run and kept after a failing one, so
# its logs can be inspected. KEEP_TEST_REPOSITORY_FOLDER=true keeps it after a
# passing run too. Set TMPDIR to choose where it's created.
module TestTmpFolder
  class << self
    attr_reader :path

    def setup
      return if @path

      @path = Dir.mktmpdir('ncbo_cron-test-')
      repository_folder = File.join(@path, 'repo')
      FileUtils.mkdir_p(repository_folder)

      LinkedData.settings.repository_folder = repository_folder
      Annotator.settings.mgrep_dictionary_file = File.join(@path, 'dictionary.txt')
      NcboCron.settings.ontology_report_path = File.join(@path, 'ontologies_report.json')

      puts "(NC) >> Using temp test folder #{@path}"
    end

    def teardown(passed:)
      return unless @path

      if !passed
        puts "(NC) >> Tests did not pass; keeping temp test folder #{@path}"
      elsif ENV['KEEP_TEST_REPOSITORY_FOLDER'] == 'true'
        puts "(NC) >> Keeping temp test folder #{@path}"
      else
        FileUtils.remove_entry(@path)
      end
      @path = nil
    end
  end

  module RunHook
    def run(*args)
      TestTmpFolder.setup
      passed = super
    ensure
      # passed is nil if the run raised, which also keeps the folder.
      TestTmpFolder.teardown(passed: passed)
    end
  end
end

Minitest.singleton_class.prepend(TestTmpFolder::RunHook)
# Check to make sure you want to run if not pointed at localhost
safe_host = Regexp.new(/localhost|-ut/)
unless LinkedData.settings.goo_host.match(safe_host) &&
       LinkedData.settings.search_server_url.match(safe_host) &&
       NcboCron.settings.redis_host.match(safe_host)
  print '\n\n================================== WARNING ==================================\n'
  print '** TESTS CAN BE DESTRUCTIVE -- YOU ARE POINTING TO A POTENTIAL PRODUCTION/STAGE SERVER **\n'
  print 'Servers:\n'
  print "triplestore -- #{LinkedData.settings.goo_host}\n"
  print "search -- #{LinkedData.settings.search_server_url}\n"
  print "redis -- #{NcboCron.settings.redis_host}\n"
  print "Type 'y' to continue: "
  $stdout.flush
  confirm = $stdin.gets
  abort('Canceling tests...\n\n') unless confirm.strip == 'y'
  print 'Running tests...'
  $stdout.flush
end

class TestCase < Minitest::Test
  include Minitest::Hooks

  def before_all
    super
    backend_triplestore_delete
  end

  private

  def count_pattern(pattern)
    q = "SELECT (count(DISTINCT ?s) as ?c) WHERE { #{pattern} }"
    rs = Goo.sparql_query_client.query(q)
    rs.each_solution do |sol|
      return sol[:c].object
    end
    0
  end

  def backend_triplestore_delete
    raise StandardError, 'Too many triples in KB, does not seem right to run tests' unless
      count_pattern('?s ?p ?o') < 400_000

    LinkedData::Models::Ontology.where.include(:acronym).each do |o|
      o.unindex_all_data
    end

    graphs = Goo.sparql_query_client.query('SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o . } }')
    graphs.each_solution do |sol|
      Goo.sparql_data_client.delete_graph(sol[:g])
    end

    LinkedData::Models::SubmissionStatus.init_enum
    LinkedData::Models::OntologyFormat.init_enum
    LinkedData::Models::OntologyType.init_enum
    LinkedData::Models::Users::Role.init_enum
    LinkedData::Models::Users::NotificationType.init_enum
  end
end
