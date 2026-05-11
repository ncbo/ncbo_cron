# frozen_string_literal: true

unless Rake::Task.task_defined?(:ensure_config)
  task :ensure_config do
    require 'bundler/setup'
    # Configure the process for the current cron configuration.
    require_relative '../lib/ncbo_cron'
    config_exists = File.exist?(File.expand_path('../../config/config.rb', __FILE__))
    abort('Please create a config/config.rb file using the config/config.rb.sample as a template') unless config_exists
    require_relative '../config/config'
  end
end

desc 'Ontology Group Administration'
namespace :group do
  desc 'Create a new ontology group'
  task :create, [:acronym, :name] => :ensure_config do |_t, args|
    checkgroup = LinkedData::Models::Group.find(args.acronym).first
    abort("FAILED: The Group #{args.groupname} already exists") unless checkgroup.nil?
    group = LinkedData::Models::Group.new
    group.name = args.name
    group.acronym = args.acronym
    if group.valid?
      group.save
    else
      puts 'FAILED: create new ontology group'
    end
  end
  desc 'Add ontology to a group'
  task :add_ontology, [:group_acronym, :ontology_acronym] => :ensure_config do |_t, args|
    grp = LinkedData::Models::Group.find(args.group_acronym).first
    abort("FAILED: The Group #{args.group_acronym} does not exist") if grp.nil?
    ontology = LinkedData::Models::Ontology.find(args.ontology_acronym).first
    abort("FAILED: The Ontology #{args.ontology_acronym} does not exist") if ontology.nil?
    ontology.bring_remaining
    group = ontology.group
    group = group.dup
    group << grp
    ontology.group = group
    if ontology.valid?
      ontology.save
    else
      puts "FAILED: add ontology #{args.ontology_acronym} to a  #{args.group_acronym} group"
    end
  end

  desc 'Delete a group after interactive confirmation'
  task :delete, [:acronym] => :ensure_config do |_t, args|
    abort('FAILED: Please provide :acronym') if args[:acronym].blank?

    group = LinkedData::Models::Group.find(args.acronym).include(LinkedData::Models::Group.attributes(:all)).first
    abort("FAILED: The #{args.acronym} group doesn't exist") if group.nil?

    abort('FAILED: Destructive operation requires interactive confirmation') unless $stdin.tty?

    print "Type yes to permanently delete group '#{args.acronym}': "
    response = $stdin.gets&.strip
    abort('Aborted: group was not deleted') unless response == 'yes'

    # Remove references to this group from ontologies
    onts = group.ontologies
    onts.each do |ont|
      ont.bring_remaining
      ont.group = ont.group.reject { |g| g.id.split('/')[-1].eql?(args.acronym) }
      if ont.valid?
        ont.save
        puts "Removed #{ont.acronym} from the #{args.acronym} group"
      else
        abort("FAILED: #{ont.acronym} is invalid and couldn't be saved: #{ont.errors}")
      end
    end

    group.delete
    puts "Deleted group '#{args.acronym}'."
    puts 'NOTE: If the API still returns stale data, clear the goo and HTTP caches.'
  end
end
