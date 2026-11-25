#!/usr/bin/env ruby

# Exit cleanly from an early interrupt
Signal.trap("INT") { exit 1 }

# Setup the bundled gems in our environment
require 'bundler/setup'
require 'json'
require 'zlib'

# Configure the process for the current cron configuration.
require_relative '../lib/ncbo_cron'
config_exists = File.exist?(File.expand_path('../../config/config.rb', __FILE__))
abort("Please create a config/config.rb file using the config/config.rb.sample as a template") unless config_exists
require_relative '../config/config'

# A Turtle file's statements without its ontology header, prefixes and blank
# lines, to tell whether a new export changes anything but those.
def ttl_statements(path)
  lines = path.end_with?(".gz") ? Zlib::GzipReader.open(path, &:readlines) : File.readlines(path)
  start = lines.index { |l| l.include?("a owl:Ontology") }
  if start
    stop = (start...lines.size).find { |i| lines[i].rstrip.end_with?(" .") } || lines.size - 1
    lines = lines[0...[start - 1, 0].max] + lines[(stop + 1)..]
  end
  lines.reject { |l| l.strip.empty? || l.start_with?("@prefix") }
end

platform = "local"
if LinkedData.settings.goo_host.include? "stage"
  platform = "stage"
elsif LinkedData.settings.goo_host.include? "prod"
  platform = "prod"
end
puts "Running on #{platform} platform"

# umls2rdf writes each UMLS release into its own subfolder, e.g. output/2026AB.
umls_output_path = "/srv/ontoportal/share/scratch/umls2rdf/output"
release = ARGV[0].to_s.strip.upcase
if release.empty?
  available = Dir.glob(File.join(umls_output_path, "*")).select { |d| File.directory?(d) }
                 .map { |d| File.basename(d) }.sort
  abort("Usage: #{File.basename($0)} <UMLS release, e.g. 2026AB>\n" \
        "Releases in #{umls_output_path}: #{available.empty? ? 'none' : available.join(', ')}")
end
umls_files_path = File.join(umls_output_path, release)
abort("#{umls_files_path} not found") unless File.directory?(umls_files_path)

# Version and release date are not set here. Metadata extraction takes them
# from each file's ontology header: owl:versionInfo and dcterms:issued
# (umls2rdf v1.4.0 and later; earlier exports have no STY header).
manifest_path = File.join(umls_files_path, "umls2rdf_manifest.json")
unless File.exist?(manifest_path)
  abort("#{manifest_path} not found: the umls2rdf export is missing or incomplete")
end
umls_version = JSON.parse(File.read(manifest_path))["umls_version"]
abort("#{manifest_path} has no umls_version") if umls_version.to_s.empty?
unless umls_version.to_s.upcase == release
  abort("#{manifest_path} is for UMLS #{umls_version}, not #{release}")
end

# Compress each export, and again when it was re-exported after its .gz was made.
Dir.glob(File.join(umls_files_path, "*.ttl")).each do |ttl|
  gz = "#{ttl}.gz"
  next if File.exist?(gz) && File.mtime(gz) >= File.mtime(ttl)
  puts "Compressing #{ttl} ..."
  LinkedData::Utils::FileHelpers.gzip_file(ttl)
end
umls_files = Dir.glob(File.join(umls_files_path, "*.ttl.gz"))

file_index = {}
umls_files.each do |x|
  if not x["semantictypes"].nil?
    file_index["STY"] = x
  else
    acr = File.basename(x, ".ttl.gz")
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
  if last.hasOntologyLanguage.nil?
    next
  end
  if last.hasOntologyLanguage.umls?
    last.status = "production"
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
pull = NcboCron::Helpers::OntologyHelper
new_submissions.each_key do |acr|
  ont, sub, file = new_submissions[acr]
  filename = file.split("/")[-1]
  # umls2rdf writes STY for every UMLS release, but the Semantic Network
  # rarely changes: submit it only when its statements do.
  if acr == "STY"
    sub.bring(:uploadFilePath) if sub.bring?(:uploadFilePath)
    previous = sub.uploadFilePath.to_s
    if File.exist?(previous) && ttl_statements(previous) == ttl_statements(file)
      puts "STY unchanged since #{previous}; no new submission"
      next
    end
  end
  pull.create_submission(ont, sub, file, filename, nil, true)
  puts "Created new submission for #{acr}"
end
