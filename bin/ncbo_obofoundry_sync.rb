#!/usr/bin/env ruby

# frozen_string_literal: true

# Exit cleanly from an early interrupt
Signal.trap('INT') { exit 1 }

# Set up the bundled gems in our environment
require 'bundler/setup'

# Use the current cron configuration
require_relative '../lib/ncbo_cron'

CONFIG_PATH = File.expand_path('../config/config.rb', __dir__)
unless File.exist?(CONFIG_PATH)
  warn 'Configuration Error: config/config.rb not found'
  warn 'Please create config/config.rb using config/config.rb.sample as a template'
  warn "Expected location: #{CONFIG_PATH}"
  exit 1
end

require_relative '../config/config'

def detect_platform
  host = LinkedData.settings.goo_host
  case host
  when /stage/
    'stage'
  when /prod/
    'prod'
  else
    'local'
  end
rescue StandardError => e
  warn "Warning: Could not detect platform from goo_host: #{e.message}"
  'unknown'
end

platform = detect_platform

require 'optparse'
require 'benchmark'
require 'logger'

options = { logfile: $stdout, log_level: Logger::INFO }
opt_parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} [options]"
  opts.separator ''
  opts.separator 'Options:'

  opts.on('-l', '--logfile FILE', 'Write log to FILE (default: STDOUT)') do |filename|
    options[:logfile] = filename
  end

  opts.on('-v', '--verbose', 'Enable verbose logging') do
    options[:log_level] = Logger::DEBUG
  end

  opts.on('-q', '--quiet', 'Suppress non-error output') do
    options[:log_level] = Logger::WARN
  end

  opts.on('-h', '--help', 'Display this help') do
    puts opts
    exit 0
  end
end

begin
  opt_parser.parse!
rescue OptionParser::InvalidOption => e
  warn "Error: #{e.message}"
  warn opt_parser.help
  exit 1
end

def setup_logger(logfile, level)
  logger = Logger.new(logfile)
  logger.level = level
  logger.formatter = proc do |severity, datetime, _progname, msg|
    "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
  end
  logger
rescue StandardError => e
  warn "Error setting up logger: #{e.message}"
  Logger.new($stdout)
end

logger = setup_logger(options[:logfile], options[:log_level])

logger.info('')
logger.info('=== ENVIRONMENT DEBUG ===')
logger.info("Ruby version: #{RUBY_VERSION}")
logger.info("Current working directory: #{Dir.pwd}")
logger.info("Script location: #{__FILE__}")
logger.info("Config path: #{CONFIG_PATH}")
logger.info("Config exists: #{File.exist?(CONFIG_PATH)}")
logger.info("USER: #{ENV['USER'] || 'not set'}")
logger.info("HOME: #{ENV['HOME'] || 'not set'}")
logger.info("PATH: #{ENV['PATH'] || 'not set'}")
logger.info("BUNDLE_GEMFILE: #{ENV['BUNDLE_GEMFILE'] || 'not set'}")
logger.info("Current user: #{`whoami`.strip rescue 'unknown'}")

# Test notification settings availability
begin
  logger.info("enable_notifications: #{LinkedData.settings.enable_notifications}")
  logger.info("email_sender: #{LinkedData.settings.email_sender}")
  logger.info("ontoportal_admin_emails: #{LinkedData.settings.ontoportal_admin_emails.inspect}")
  logger.info("smtp_host: #{LinkedData.settings.smtp_host}")
rescue StandardError => e
  logger.error("Error accessing LinkedData settings: #{e.message}")
end
logger.info('=== END ENVIRONMENT DEBUG ===')
logger.info('')

log_destination = options[:logfile] == $stdout ? 'STDOUT' : options[:logfile]
logger.info("OBO Foundry sync starting - logging to #{log_destination}")
logger.info("Platform: #{platform}")

begin
  require_relative '../lib/ncbo_cron/obofoundry_sync'

  sync_runner = NcboCron::Models::OBOFoundrySync.new

  logger.info('Starting OBO Foundry synchronization...')
  time = Benchmark.realtime { sync_runner.run }

  logger.info("OBO Foundry synchronization completed successfully in #{time.round(2)} seconds")
rescue StandardError => e
  logger.error("OBO Foundry sync failed: #{e.class}: #{e.message}")
  logger.debug("Backtrace:\n#{e.backtrace.to_a.join("\n")}")
  exit 1
ensure
  logger.info('OBO Foundry sync process finished')
end
