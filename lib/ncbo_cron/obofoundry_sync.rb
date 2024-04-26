require 'faraday'
require 'faraday/follow_redirects'
require 'multi_json'

module NcboCron
  module Models
    class OBOFoundrySync

      def initialize
        @logger = Logger.new(STDOUT)
      end

      def run
        # Get a map of OBO ID spaces to BioPortal acronyms
        map = get_ids_to_acronyms_map

        onts = get_obofoundry_ontologies
        @logger.info("Found #{onts.size} OBO Foundry ontologies")

        # Are any OBO Foundry ontologies missing from BioPortal?
        missing_onts = []
        active_onts = onts.reject { |ont| ont.key?('is_obsolete') }
        @logger.info("#{active_onts.size} OBO Foundry ontologies are currently active")
        active_onts.each do |ont|
          if not map.key?(ont['id'])
            missing_onts << ont
            @logger.info("Missing OBO Foundry ontology: #{ont['title']} (#{ont['id']})")
          end
        end

        # Have any of the OBO Foundry ontologies that BioPortal hosts become obsolete?
        obsolete_onts = []
        ids = active_onts.map{ |ont| ont['id'] }
        obsolete_ids = map.keys - ids
        obsolete_ids.each do |id|
          ont = onts.find{ |ont| ont['id'] == id }
          @logger.info("Deprecated OBO Library ontology: #{ont['title']} (#{ont['id']})")
          obsolete_onts << ont
        end        

        LinkedData::Utils::Notifications.obofoundry_sync(missing_onts, obsolete_onts)
      end

      def get_ids_to_acronyms_map
        response = Faraday.get('https://ncbo.github.io/oboids_to_bpacronyms.json')
        MultiJson.load(response.body)
      end

      def get_obofoundry_ontologies
        conn = Faraday.new do |faraday|
          faraday.response :follow_redirects
          faraday.adapter Faraday.default_adapter
        end
        response = conn.get('http://purl.obolibrary.org/meta/ontologies.jsonld')

        MultiJson.load(response.body)['ontologies']
      end
    end
  end
end
