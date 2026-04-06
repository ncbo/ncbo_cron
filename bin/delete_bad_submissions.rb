#!/usr/bin/env ruby

# Exit cleanly from an early interrupt
Signal.trap("INT") { exit 1 }

# Setup the bundled gems in our environment
require 'bundler/setup'

# Configure the process for the current cron configuration.
require_relative '../lib/ncbo_cron'
config_exists = File.exist?(File.expand_path('../../config/config.rb', __FILE__))
abort("Please create a config/config.rb file using the config/config.rb.sample as a template") unless config_exists
require_relative '../config/config';
require 'optparse'

options = {}
opt_parser = OptionParser.new do |opts|
  options[:logfile] = STDOUT
  opts.on( '-l', '--logfile FILE', "Write log to FILE (default is STDOUT)" ) do |filename|
    options[:logfile] = filename
  end

  # Display the help screen, all programs are assumed to have this option.
  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end
end
# Parse the command-line. The 'parse' method simply parses ARGV, while the 'parse!' method parses ARGV and removes
# any options found there, as well as any parameters for the options.
opt_parser.parse!

#######################################################################################################################
#
# MAIN
#
logger = Logger.new(options[:logfile])
acronyms = []
bad_subs = []

LinkedData::Models::Ontology.all.each do |ont|
  ont.bring_remaining
  acronym = ont.acronym
  next unless acronyms.empty? || acronyms.include?(acronym)

  ont.bring(:submissions)
  ont.submissions.each do |s|
    s.bring(:submisionId)
    s.bring(:hasOntologyLanguage)
    s.bring_remaining

    begin
      unless s.submissionId.is_a? Fixnum
        bad_subs << s
        logger.info("Submission id is not numeric #{s.id}: #{s.submissionId.class}")
      end
    rescue SystemExit, Interrupt
      raise
    rescue StandardError => e
      bad_subs << s
      logger.info("Error retrieving submission id #{s.id}: #{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}")
    end

    begin
      if s.hasOntologyLanguage.nil?
        bad_subs << s
        puts "#{s.id}: hasOntologyLanguage nil"
      end
    rescue SystemExit, Interrupt
      raise
    rescue StandardError => e
      bad_subs << s
      logger.info("Error retrieving hasOntologyLanguage for submission #{s.id}: #{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}")
    end
  end
end

bad_subs.each {|s| logger.info("Deleting submission: #{s.id}"); s.delete}
logger.info("Number of bad submissions: #{bad_subs.length}")
