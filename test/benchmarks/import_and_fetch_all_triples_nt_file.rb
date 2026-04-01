
# Documentation:
# This script is used to import a large NT file into the triple store
# and then fetch all the triples by paginating through the triples.
# The script is used to compare the performance of the import and fetch of different backends.

profile = ARGV[0]
file_path = ARGV[1]
acronym = ARGV[2] || 'STY' # Default to STY
pwd = File.dirname(__FILE__)
system("#{pwd}/start_ontoportal_services.sh #{profile} #{acronym}")

if $?.exitstatus != 0
  puts "Error occurred during script execution."
  exit(1)
end

if file_path == nil
  puts "Error: Missing arguments. Please provide the file path."
  exit(1)
end

puts "Finished parsing file"
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
require_relative 'data_benchs'

puts "Starting to fetch triples"
sub = LinkedData::Models::Ontology.find(acronym).first.latest_submission(status: :any)
sub.bring_remaining

Benchmarks.bench('Append triples') do
  Benchmarks.import_nt_file(sub, file_path)
end

Benchmarks.do_all_benchmarks(sub)
