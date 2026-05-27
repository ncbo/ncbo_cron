# frozen_string_literal: true

# Ontology administration and reporting tasks.

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

desc 'Ontology reporting'
namespace :ontology do
  desc 'Comma-separated list of ontologies created or with new submissions in the last N days (default 30)'
  task :recent, [:days] => :ensure_config do |_t, args|
    args.with_defaults(days: '30')
    days = args.days.to_i
    abort('FAILED: :days must be a positive integer, e.g. rake ontology:recent[15]') unless days.positive?
    cutoff = DateTime.now - days

    # An ontology has no creation date of its own; it is derived from its earliest
    # submission. Any ontology with an in-window submission therefore qualifies as
    # either newly created (first submission in window) or newly updated (later one).
    submissions = LinkedData::Models::OntologySubmission.where
                                                        .include(:creationDate)
                                                        .include(ontology: [:acronym])
                                                        .all

    acronyms = submissions.select { |s| s.creationDate && s.creationDate >= cutoff }
                          .map { |s| s.ontology&.acronym }
                          .compact
                          .uniq
                          .sort

    puts acronyms.join(', ')
  end
end
