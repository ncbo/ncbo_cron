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
# ont_acronyms = ["MI"]
# ont_acronyms = ["OHD"]
# ont_acronyms = ["MMO"]
# ont_acronyms = ["MF"]
# ont_acronyms = ["ONTODM-CORE"]
# ont_acronyms = ["FAST-FORMGENRE"]
# ont_acronyms = ["ALLERGYDETECTOR"]
# ont_acronyms = ["WETAXTOPICS"]
# ont_acronyms = ["ONTODRC"]

onts = []
SPACER = "\n\n\n"
UNKNOWN_CONTACT = {
  name: "Unknown",
  email: "noreply@bioontology.org"
}
DEFAULT_URI = "http://www.example.com"

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

def additional_datatype_fix(type, value, logger)
  case type.to_s
  when "RDF::URI"
    value = fix_invalid_uri(value, logger: logger)
  else
    # type code here
  end
  value
end

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

def resolve_klass(target_type, logger)
  klass = Object.const_get(target_type.split("::").first)
  target_type.split("::")[1..].each { |const| klass = klass.const_get(const) }
  klass
rescue NameError => e
  logger.error("Could not resolve class #{target_type}: #{e.message}#{SPACER}")
  nil
end

def fix_single_attribute(sub, attribute_name, klass, logger)
  original_value = sub.send(attribute_name)
  casted_value = klass.new(original_value)
  casted_value = additional_datatype_fix(klass, casted_value, logger)
  sub.send("#{attribute_name}=", casted_value)
  logger.info("Attribute \"#{attribute_name}\". Replaced \"#{original_value}\" with \"#{klass}('#{casted_value}')\"")
rescue => e
  logger.error("Error assigning #{attribute_name} to #{klass}: #{e.message}#{SPACER}")
end

def fix_array_attribute(sub, attribute_name, klass, logger)
  current_value = sub.send(attribute_name)
  values = current_value.is_a?(Array) ? current_value : [current_value]

  casted_values = values.map do |val|
    begin
      klass.new(val)
      additional_datatype_fix(klass, val, logger)
    rescue => e
      logger.error("Skipping value '#{val}' for #{attribute_name}: #{e.message}")
      nil
    end
  end.compact

  sub.send("#{attribute_name}=", casted_values)
  logger.info("Attribute \"#{attribute_name}\". Cast each list value to #{klass}: #{casted_values.inspect}")
rescue => e
  logger.error("Error processing array for #{attribute_name}: #{e.message}#{SPACER}")
end

def fix_existence_error(sub, attr, logger)
  case attr
  when :contact
    contact = Contact.where(email: UNKNOWN_CONTACT[:email]).first
    contact = Contact.new(UNKNOWN_CONTACT).save unless contact
    sub.contact = [contact]
    logger.info("Attribute \"#{attr}\" was empty. Added default contact: \"#{UNKNOWN_CONTACT.inspect}\"")
  else
    # type code here
  end
end

def process_errors(sub, error_hash, logger)
  error_hash.each do |attr, value_hash|
    value_hash.each do |key, message|
      if key == :existence
        fix_existence_error(sub, attr, logger)
      elsif match = message.match(/Attribute `(.+?)` with the value `(.+?)` must be `(.+?)`/)
        attribute_name = match[1]
        target_type = match[3]
        klass = resolve_klass(target_type, logger)
        fix_single_attribute(sub, attribute_name, klass, logger) if klass
      elsif match = message.match(/All values in attribute `(.+?)` must be `(.+?)`/)
        attribute_name = match[1]
        target_type = match[2]
        klass = resolve_klass(target_type, logger)
        fix_array_attribute(sub, attribute_name, klass, logger) if klass
      end
    end
  end
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

    if sub.valid?
      logger.info("Nothing to fix for #{ont.acronym}#{SPACER}")
      next
    end

    error_hash = sub.errors
    logger.info("Errors: #{error_hash}\n")

    if error_hash && !error_hash.empty?
      process_errors(sub, error_hash, logger)
      ensure_valid_does_not_crash(sub, logger: logger)

      if sub.valid?
        sub.save
        logger.info("Fixed submission for ontology #{ont.acronym} with id #{sub.id}#{SPACER}")
      else
        logger.error("Unable to fix latest submission for ontology #{ont.acronym} with id #{sub.id}: #{sub.errors}#{SPACER}")
        unfixed_acronyms << ont.acronym
      end
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
