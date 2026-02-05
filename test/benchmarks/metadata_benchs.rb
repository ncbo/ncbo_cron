require 'ontologies_linked_data'
require_relative 'data_benchs'
module Benchmarks
  module Metadata

    def self.do_all_benchmarks
      Benchmarks.bench("Fetch all ontologies (display=all)") do
        self.all_ontologies
      end

      Benchmarks.bench("Fetch all submissions (display=all)") do
        Goo.logger.info("Fetching all submissions")
        self.all_submissions
      end

    end


    def self.all_ontologies
      attr_ontology = LinkedData::Models::Ontology.attributes(:all)
      count = LinkedData::Models::Ontology.where.include(attr_ontology).all.count
      puts "Total ontologies: #{count}"
    end

    def self.all_submissions
      attr_ontology = LinkedData::Models::Ontology.attributes(:all)
      attr = LinkedData::Models::OntologySubmission.attributes(:all)
      attr << { ontology: attr_ontology }
      count = LinkedData::Models::OntologySubmission.where.include(attr).all.count
      puts "Total submissions: #{count}"
    end
  end
end
