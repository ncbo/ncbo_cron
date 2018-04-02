#!/usr/bin/env ruby

# Exit cleanly from an early interrupt
Signal.trap("INT") { exit 1 }

# Setup the bundled gems in our environment
require 'bundler/setup'

# Configure the process for the current cron configuration.
require_relative '../lib/ncbo_cron'
config_exists = File.exist?(File.expand_path('../../config/config.rb', __FILE__))
abort("Please create a config/config.rb file using the config/config.rb.sample as a template") unless config_exists
require_relative '../config/config'

platform = "local"
if LinkedData.settings.goo_host.include? "stage"
  platform = "stage"
elsif LinkedData.settings.goo_host.include? "prod"
  platform = "prod"
end
puts "Running on #{platform} platform"

umls_files_path = "/srv/ncbo/share/scratch/umls2rdf/output"
umls_files = Dir.glob(File.join(umls_files_path, "*.ttl"))

# UMLS Release Details.  Update this for new release
new_version = "2017AB"
new_released = "2017-05-09" #Release date

file_index = {}
umls_files.each do |x|
  if not x["semantictypes"].nil?
    file_index["STY"] = x
  else
    acr = x.split("/")[-1][0..-5]
    file_index[acr] = x
  end
end
puts "Retrieving umls ontologies ..."
onts = LinkedData::Models::Ontology.where.include(:hasOntologyLanguage,:acronym).all
umls_index = {}
onts.each do |o|
  last = o.latest_submission(status: :any)
  if last.nil?
    next
  end
  last.bring(:hasOntologyLanguage)
  if last.hasOntologyLanguage.umls?
    umls_index[o.acronym] = [o,last]
  end
end
puts "Retrieved #{umls_index.count} umls ontologies"
new_submissions = {}
file_index.each do |acr,file_path|
  if umls_index.include?(acr)
    ont,sub = umls_index[acr]
    new_submissions[acr] = [ont,sub,file_path]
  else
    puts "Ontology not found for file #{file_path}"
  end
end
puts "#{new_submissions.length} new files mapped to ontologies"
pull = NcboCron::Models::OntologyPull.new
new_submissions.each_key do |acr|
  ont, sub, file = new_submissions[acr]
  filename = file.split("/")[-1]
  pull.create_submission(ont,sub,file,filename,logger=nil,
                         add_to_pull=false,new_version,new_released)
  puts "Created new submission for #{acr}"
end
