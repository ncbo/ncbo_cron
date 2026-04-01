# frozen_string_literal: true

namespace :slice do
  task :environment do
    require 'bundler/setup'
    # Configure the process for the current cron configuration.
    require_relative '../lib/ncbo_cron'
    config_exists = File.exist?(File.expand_path('../config/config.rb', __dir__))
    abort('Please create a config/config.rb file using the config/config.rb.sample as a template') unless config_exists
    require_relative '../config/config'
  end

  desc 'Create a new ontology slice. ontology_acronyms must be a space-separated list. ' \
       'Example: "slice:create[test,Test Slice,ZECO ZFS ZP,This is a test slice]"'
  task :create, [:acronym, :name, :ontology_acronyms, :description] => :environment do |_t, args|
    abort('FAILED: Please provide :acronym') if args.acronym.to_s.strip.empty?
    abort('FAILED: Please provide :name') if args.name.to_s.strip.empty?
    abort('FAILED: Please provide :ontology_acronyms (space-separated)') if args.ontology_acronyms.to_s.strip.empty?

    checkslice = LinkedData::Models::Slice.find(args.acronym).first
    abort("FAILED: The '#{args.acronym}' slice already exists") unless checkslice.nil?

    ontology_acronyms = args.ontology_acronyms.split(/\s+/).map(&:strip).reject(&:empty?).uniq
    ontologies = ontology_acronyms.map do |acr|
      ontology = LinkedData::Models::Ontology.find(acr).first
      abort("FAILED: The '#{acr}' ontology does not exist") if ontology.nil?
      ontology.bring_remaining
      ontology
    end

    slice_data = {
      acronym: args.acronym,
      name: args.name,
      ontologies: ontologies
    }
    slice_data[:description] = args.description unless args.description.to_s.strip.empty?
    slice = LinkedData::Models::Slice.new(slice_data)

    if slice.valid?
      slice.save
      count = ontologies.length
      label = count == 1 ? 'ontology' : 'ontologies'
      puts "Created slice '#{args.acronym}' with #{count} #{label}. " \
           'If API still returns stale data, clear the goo and HTTP caches.'
    else
      puts 'FAILED: create new ontology slice'
    end
  end

  desc 'Add ontology to a slice'
  task :add_ontology, [:slice_acronym, :ontology_acronym] => :environment do |_t, args|
    slice = LinkedData::Models::Slice.find(args.slice_acronym).first
    abort("FAILED: The slice '#{args.slice_acronym}' does not exist") if slice.nil?
    slice.bring_remaining

    ontology = LinkedData::Models::Ontology.find(args.ontology_acronym).first
    abort("FAILED: The ontology '#{args.ontology_acronym}' does not exist") if ontology.nil?
    ontology.bring_remaining

    ontologies = slice.ontologies.dup
    ontologies << ontology unless ontologies.any? { |o| o.id.to_s == ontology.id.to_s }
    slice.ontologies = ontologies

    if slice.valid?
      slice.save
      puts "Added #{ontology.acronym} to slice '#{slice.acronym}'. " \
           'If API still returns stale data, clear the goo and HTTP caches.'
    else
      puts "FAILED: add ontology #{ontology.acronym} to slice '#{slice.acronym}'"
    end
  end

  desc 'Remove ontology from a slice'
  task :remove_ontology, [:slice_acronym, :ontology_acronym] => :environment do |_t, args|
    slice = LinkedData::Models::Slice.find(args.slice_acronym).first
    abort("FAILED: The slice '#{args.slice_acronym}' does not exist") if slice.nil?
    slice.bring_remaining

    ontology = LinkedData::Models::Ontology.find(args.ontology_acronym).first
    abort("FAILED: The ontology '#{args.ontology_acronym}' does not exist") if ontology.nil?
    ontology.bring_remaining

    ontologies = slice.ontologies.reject { |o| o.id.to_s == ontology.id.to_s }
    if ontologies.length == slice.ontologies.length
      abort("FAILED: The ontology #{ontology.acronym} is not in slice '#{slice.acronym}'")
    end
    abort("FAILED: slice '#{slice.acronym}' must contain at least one ontology") if ontologies.empty?

    slice.ontologies = ontologies

    if slice.valid?
      slice.save
      puts "Removed #{ontology.acronym} from slice '#{slice.acronym}'. " \
           'If API still returns stale data, clear the goo and HTTP caches.'
    else
      puts "FAILED: remove ontology #{ontology.acronym} from slice '#{slice.acronym}'"
    end
  end

  desc 'Delete a slice after interactive confirmation'
  task :delete, [:slice_acronym] => :environment do |_t, args|
    abort('FAILED: Please provide :slice_acronym') if args.slice_acronym.to_s.strip.empty?

    slice = LinkedData::Models::Slice.find(args.slice_acronym).first
    abort("FAILED: The '#{args.slice_acronym}' slice does not exist") if slice.nil?

    abort('FAILED: Destructive operation requires interactive confirmation') unless $stdin.tty?

    print "Type yes to permanently delete slice '#{args.slice_acronym}': "
    response = $stdin.gets&.strip
    abort('Aborted: slice was not deleted') unless response == 'yes'

    slice.bring_remaining
    slice.delete
    puts "Deleted slice '#{args.slice_acronym}'. If API still returns stale data, clear the goo and HTTP caches."
  end
end
