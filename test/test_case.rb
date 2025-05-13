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
require 'ontologies_linked_data'
require_relative '../lib/ncbo_cron'
require_relative '../config/config'

Goo.use_cache = false # Make sure tests don't cache

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

  def after_all
    super
  end

  # http://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers#Dynamic.2C_private_or_ephemeral_ports
  def self.unused_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
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
      count_pattern('?s ?p ?o') < 400000

    LinkedData::Models::Ontology.where.include(:acronym).each do |o|
      query = "submissionAcronym:#{o.acronym}"
      LinkedData::Models::Ontology.unindexByQuery(query)
    end
    LinkedData::Models::Ontology.indexCommit
    Goo.sparql_update_client.update('DELETE {?s ?p ?o } WHERE { ?s ?p ?o }')
    LinkedData::Models::SubmissionStatus.init_enum
    LinkedData::Models::OntologyFormat.init_enum
    LinkedData::Models::OntologyType.init_enum
    LinkedData::Models::Users::Role.init_enum
    LinkedData::Models::Users::NotificationType.init_enum
  end
end
