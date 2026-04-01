#!/usr/bin/env ruby
require 'logger'
require 'optparse'

module NcboCron
  class GraphsCounts
    SUBMISSION_DATA_GRAPH = 'http://data\.bioontology\.org/ontologies/[^/]+/submissions/\d+'
    DATA_SAVE = '/srv/ontoportal/data/reports/graph_counts.json'

    attr_reader :logger, :file_path

    def initialize(logger = nil, file_path = nil)
      @file_path = file_path || DATA_SAVE
      @logger = logger || Logger.new(STDOUT)
    end

    def read_graph_counts
      return {} unless File.exist?(file_path)

      JSON.parse(File.read(file_path))
    end

    def run
      logger.info('Start generating graphs counts')
      logger.info('Fetch ontologies data graphs')
      @all_ontologies = LinkedData::Models::Ontology.all
      @all_subs = @all_ontologies.map{|x| x.latest_submission(status: :any)}.compact

      logger.info('Fetch all graphs URIs')
      graphs = graphs_list
      result = {}
      graphs.each do |graph|
        logger.info("Calculate the triple count of #{graph}")
        result[graph] = [graph_count_triples(graph), zombie_graph?(graph)]
      end

      logger.info("Save the result in file #{file_path}")
      save_result_in_file(file_path, result)
      logger.info('Finish generating graphs counts')
    end


    private

    def save_result_in_file(file_path, results)
      File.open(file_path, 'w') do |f|
        f.write(results.to_json)
      end
    end

    def zombie_graph?(graph)
      regex = Regexp.new(SUBMISSION_DATA_GRAPH)
      return false unless regex.match?(graph)

      !@all_subs.find{ |x| x.id.to_s == graph.to_s }.present?
    end

    def graph_count_triples(graph)
      query = <<-eos
            SELECT (COUNT(?s) as ?count) WHERE {
            GRAPH <#{graph}> {
              ?s ?p ?v
            }}
      eos
      rs = Goo.sparql_query_client.query(query)
      count = 0
      rs.each_solution do |sol|
        count = sol[:count].object
      end
      count
    end

    def graphs_list
      query = <<-eos
            SELECT DISTINCT ?g WHERE {
            GRAPH ?g {
              ?s ?p ?v
            }}
      eos
      rs = Goo.sparql_query_client.query(query)
      rs.each_solution.map { |x| x[:g].to_s }
    end
  end
end