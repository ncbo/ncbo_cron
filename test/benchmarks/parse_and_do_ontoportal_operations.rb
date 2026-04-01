require 'benchmark'
acronym = ARGV[0]
profile = ARGV[1]
api_key = ARGV[2] || '1de0a270-29c5-4dda-b043-7c3580628cd5'
api_url = ARGV[3] || 'http://data.stageportal.lirmm.fr'
pwd = File.dirname(__FILE__)

system("bash #{pwd}/start_ontoportal_services.sh #{profile} #{acronym} #{api_key} #{api_url}")
if $?.exitstatus != 0
  puts "Error occurred during running services script execution."
  exit(1)
end

case profile
when 'ag'
  # AllegroGraph backend
  ENV['GOO_BACKEND_NAME'] = 'allegrograph'
  ENV['GOO_PORT'] = '10035'
  ENV['GOO_PATH_QUERY'] = '/repositories/ontoportal_test'
  ENV['GOO_PATH_DATA'] = '/repositories/ontoportal_test/statements'
  ENV['GOO_PATH_UPDATE'] = '/repositories/ontoportal_test/statements'
  ENV['COMPOSE_PROFILES'] = 'ag'

when 'fs'
  # 4store backend
  ENV['GOO_PORT'] = '9000'
  ENV['COMPOSE_PROFILES'] = 'fs'

when 'vo'
  # Virtuoso backend
  ENV['GOO_BACKEND_NAME'] = 'virtuoso'
  ENV['GOO_PORT'] = '8890'
  ENV['GOO_PATH_QUERY'] = '/sparql'
  ENV['GOO_PATH_DATA'] = '/sparql'
  ENV['GOO_PATH_UPDATE'] = '/sparql'
  ENV['COMPOSE_PROFILES'] = 'vo'

when 'gb'
  # Graphdb backend
  ENV['GOO_BACKEND_NAME'] = 'graphdb'
  ENV['GOO_PORT'] = '7200'
  ENV['GOO_PATH_QUERY'] = '/repositories/ontoportal'
  ENV['GOO_PATH_DATA'] = '/repositories/ontoportal/statements'
  ENV['GOO_PATH_UPDATE'] = '/repositories/ontoportal/statements'

else
  puts "Error: Unknown backend type. Please set BACKEND_TYPE to 'ag', 'fs', 'vo', or 'gb'."
end

puts "Parsing file for #{acronym} and #{profile}"
time = Benchmark.realtime do
  system("#{pwd}/../../bin/ncbo_ontology_process -o #{acronym} -t process_rdf")
end
puts "Time to parse file: " + time.round(2).to_s + 's'

if $?.exitstatus != 0
  puts "Error occurred during script execution."
  exit(1)
end
puts "Finished parsing file"

require 'bundler/setup'
require 'pry'
require 'benchmark'
require 'ncbo_annotator'
require 'ncbo_cron'
require 'ontologies_linked_data'
require_relative '../../config/config'
require_relative './metadata_benchs'
require_relative './data_benchs'
Goo.sparql_query_client.cache.redis_cache.flushdb
sub = LinkedData::Models::Ontology.find(acronym).first.latest_submission(status: :any)

Benchmarks.do_all_benchmarks(sub)
