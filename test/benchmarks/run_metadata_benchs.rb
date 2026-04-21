require 'benchmark'
profile = ARGV[0]
pwd = File.dirname(__FILE__)

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



require 'bundler/setup'
require 'pry'
require 'benchmark'
require 'ncbo_annotator'
require 'ncbo_cron'
require 'ontologies_linked_data'
require_relative '../../config/config'
require_relative './metadata_benchs'

Goo.sparql_query_client.cache.redis_cache.flushdb


Benchmarks::Metadata.do_all_benchmarks
