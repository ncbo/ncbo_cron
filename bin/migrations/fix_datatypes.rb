require 'ontologies_linked_data'
require 'ncbo_annotator'
require 'rdf'
require 'fileutils'
require_relative '../../lib/ncbo_cron/config'
require_relative '../../config/config'


Ontology = LinkedData::Models::Ontology
Contact = LinkedData::Models::Contact
# ont_acronyms = ["BAO", "CDAO", "CMPO", "DOID", "EMAPA", "GPML", "LABO", "MF", "MI", "MMO", "OHD", "RDA-ISSUANCE"]
# ont_acronyms = ["RDA-ISSUANCE"]
# ont_acronyms = ["BAO"]
# ont_acronyms = ["WHO"]
# ont_acronyms = ["MEDDRA"]
# ont_acronyms = ["WINDENERGY", "MEDDRA"]
# ont_acronyms = ["WHOFRE"]
# ont_acronyms = ["MF"]
# ont_acronyms = ["ONTODM-CORE"]
# ont_acronyms = ["FAST-FORMGENRE"]
# ont_acronyms = ["ALLERGYDETECTOR"]
# ont_acronyms = ["WETAXTOPICS"]
# ont_acronyms = ["H1_NMOABA_4_1"]
# ont_acronyms = ["XAO"]

onts = []
SPACER = "\n\n\n"
UNKNOWN_CONTACT = {
  name: "Unknown",
  email: "noreply@bioontology.org"
}
DEFAULT_URI = "http://www.example.com"
ATTRIBUTES_TO_FIX = {
  documentation: {
    predicate: RDF::URI.new("#{Goo.namespaces[:omv].to_s}documentation"),
    is_single: true
  },
  homepage: {
    predicate: RDF::URI.new("#{Goo.namespaces[:metadata].to_s}homepage"),
    is_single: true
  },
  publication: {
    predicate: RDF::URI.new("#{Goo.namespaces[:metadata].to_s}publication"),
    is_single: false
  },
  uri: {
    predicate: RDF::URI.new("#{Goo.namespaces[:omv].to_s}uri"),
    is_single: true
  }
}

def ensure_valid_does_not_crash(sub, logger:)
  begin
    sub.valid?
  rescue ArgumentError => e
    if (match = e.message.match(/File path (.+?) not found/))
      missing_path = match[1]

      begin
        FileUtils.mkdir_p(File.dirname(missing_path))
        File.write(missing_path, "")

        logger.warn("Created missing file: #{missing_path} to allow validation to proceed")
      rescue => file_error
        logger.error("Failed to create missing file #{missing_path}: #{file_error.message}")
      end
    else
      logger.error("Unhandled validation error: #{e.class} - #{e.message}")
    end
  end
end

def fix_invalid_uri(value, logger:, default_scheme: "http", fallback_uri: DEFAULT_URI)
  if value.nil? || value.to_s.strip.empty?
    logger.warn("Received nil or empty URI value, replacing with default: #{fallback_uri}")
    return RDF::URI.new(fallback_uri)
  end

  cleaned_val = value.to_s.strip
  uri = RDF::URI.new(cleaned_val)
  return uri if uri.valid?

  # Try to fix by adding a default scheme if missing
  unless cleaned_val.to_s.match?(/^https?:\/\//)
    corrected_value = "#{default_scheme}://#{cleaned_val}"
    corrected_uri = RDF::URI.new(corrected_value)
    return corrected_uri if corrected_uri.valid?
  end

  # Still invalid — fallback
  logger.warn("The value '#{value}' is completely invalid, replacing with default URI: #{fallback_uri}")
  RDF::URI.new(fallback_uri)
end

def delete_original_value(sub, attribute_name, logger:)
  query = <<~SPARQL
    DELETE {
      GRAPH <#{sub.graph.to_s}> {
        <#{sub.id.to_s}> <#{ATTRIBUTES_TO_FIX[attribute_name.to_sym][:predicate].to_s}> ?o .
      }
    }
    WHERE {
      GRAPH <#{sub.graph.to_s}> {
        <#{sub.id.to_s}> <#{ATTRIBUTES_TO_FIX[attribute_name.to_sym][:predicate].to_s}> ?o .
      }
    }
  SPARQL
  Goo.sparql_query_client.update(query)
  logger.info("Deleted original value of #{attribute_name} for #{sub.id.to_s}")
end

def process_single_attribute(sub, attribute_name, logger:)
  is_single = ATTRIBUTES_TO_FIX[attribute_name.to_sym][:is_single]
  query = <<~SPARQL
    SELECT ?o
    FROM <#{sub.graph.to_s}>
    WHERE {
      <#{sub.id.to_s}> <#{ATTRIBUTES_TO_FIX[attribute_name.to_sym][:predicate].to_s}> ?o .
    }
  SPARQL
  rs = Goo.sparql_query_client.query(query)
  old_vals = []
  new_vals = []

  rs.each do |result|
    old_vals << result[:o]
    new_vals << fix_invalid_uri(result[:o].to_s, logger: logger)
    break if ATTRIBUTES_TO_FIX[attribute_name.to_sym][:is_single]
  end

  unless rs.empty?
    casted_val = ATTRIBUTES_TO_FIX[attribute_name.to_sym][:is_single] ? new_vals.first : new_vals.compact.uniq
    delete_original_value(sub, attribute_name, logger: logger)
    sub.send("#{attribute_name}=", casted_val)
    logger.info("Attribute #{attribute_name}. Corrected value: #{casted_val.inspect}')")
  end
rescue => e
  logger.error("Error assigning #{attribute_name} to #{casted_val.inspect}: #{e.message}#{SPACER}")
end

def fix_contact(sub, logger:)
  return if sub.contact
  contact = Contact.where(email: UNKNOWN_CONTACT[:email]).first
  contact = Contact.new(UNKNOWN_CONTACT).save unless contact
  sub.contact = [contact]
  logger.info("Contact for #{sub.id.to_s} was empty. Added default contact: \"#{UNKNOWN_CONTACT.inspect}\"")
end

# ---------------
# 🧼 Execution
# ---------------

logger = Logger.new($stdout)
unfixed_acronyms = []
start_time = Time.now

if !defined?(ont_acronyms) || ont_acronyms.empty?
  onts = Ontology.where.include(Ontology.attributes).all
else
  ont_acronyms.each do |acronym|
    ont = Ontology.find(acronym).include(Ontology.attributes).first
    onts << ont if ont
  end
end

logger.info("There are a total of #{onts.length} ontologies to process...#{SPACER}")

onts.each do |ont|
  begin
    sub = ont.latest_submission(status: :any)
    next unless sub
    sub.bring_remaining
    logger.info("Ontology: #{ont.acronym}")

    if sub.nil?
      logger.info("No submission found for #{ont.acronym}#{SPACER}")
      next
    end

    ensure_valid_does_not_crash(sub, logger: logger)

    ATTRIBUTES_TO_FIX.each_key { |name|
      process_single_attribute(sub, name, logger: logger)
    }

    fix_contact(sub, logger: logger)

    if sub.valid?
      sub.save
      logger.info("Fixed submission for ontology #{ont.acronym} with id #{sub.id}#{SPACER}")
    else
      logger.error("Unable to fix latest submission for ontology #{ont.acronym} with id #{sub.id}: #{sub.errors}#{SPACER}")
      unfixed_acronyms << ont.acronym
    end
  rescue StandardError => e
    logger.error(e)
  end
end

end_time = Time.now
duration = end_time - start_time

if duration >= 60
  logger.info("Completed processing in #{(duration / 60).round(1)} minutes")
else
  logger.info("Completed processing in #{duration.round(2)} seconds")
end

logger.info("Unfixed ontologies: #{unfixed_acronyms.empty?? "none" : unfixed_acronyms.map { |s| "\"#{s}\"" }.join(", ")}")
