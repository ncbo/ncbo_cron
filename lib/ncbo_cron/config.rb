require 'ostruct'

module NcboCron
  extend self
  attr_reader :settings

  @settings = OpenStruct.new
  @settings_run = false
  def config(&block)
    return if @settings_run
    @settings_run = true

    # Redis is used for two separate things in ncbo_cron:
    # 1) locating the queue for the submissions to be processed and
    # 2) managing the processing lock.
    @settings.redis_host ||= "localhost"
    @settings.redis_port ||= 6379
    puts "(CR) >> Using Redis instance at #{@settings.redis_host}:#{@settings.redis_port}"

    # Daemon
    @settings.daemonize ||= true
    # REPL for working with scheduler
    @settings.console ||= false
    # submission id to add to the queue
    @settings.queue_submission ||= nil
    # view queued jobs
    @settings.view_queue ||= false
    @settings.enable_processing ||= true
    @settings.enable_pull ||= true
    @settings.enable_flush ||= true
    # Don't remove graphs from deleted ontologies by default when flushing classes
    @settings.remove_zombie_graphs ||= false
    @settings.enable_warmq ||= true
    @settings.enable_mapping_counts ||= true
    # enable ontology analytics (GA4)
    @settings.enable_ontology_analytics ||= true
    # enable ontology analytics (cloudflare)
    @settings.enable_cloudflare_analytics ||= true
    # enable ontology rank generation
    @settings.enable_ontology_rank ||= true
    # enable graph count
    @settings.enable_graphs_counts ||= true
    # enable ontologies report
    @settings.enable_ontologies_report ||= true
    # enable index synchronization
    @settings.enable_index_synchronizer ||= true
    # enable SPAM deletion
    @settings.enable_spam_deletion ||= true
    # enable update check (vor VMs)
    @settings.enable_update_check ||= true
    # enable mgrep dictionary generation job
    @settings.enable_dictionary_generation_cron_job ||= false

    @settings.enable_obofoundry_sync ||= true

    # Schedules
    # 30 */4 * * * - run every 4 hours, starting at 00:30
    @settings.cron_schedule ||= "30 */4 * * *"
    # Pull schedule.
    # 00 18 * * * - run daily at 6 a.m. (18:00)
    @settings.pull_schedule ||= "00 18 * * *"
    # Delete class graphs of archive submissions
    @settings.cron_flush ||= "00 22 * * 2"
    # Warmup long time running queries.
    # 00 */3 * * * - run every 3 hours (beginning at 00:00)
    @settings.cron_warmq ||= "00 */3 * * *"
    # Create mapping counts schedule
    # 30 0 * * 6 - run once per week on Saturday at 12:30AM
    @settings.cron_mapping_counts ||= "30 0 * * 6"
    # Ontology analytics refresh schedule
    # 15 0 * * 1 - run once a week on Monday at 12:15AM
    @settings.cron_ontology_analytics ||= "15 0 * * 1"
    # Cloudflare analytics schedule
    # 0 1 * * * - run daily at 1:00am
    @settings.cron_cloudflare_analytics ||= '0 1 * * *'
    # Ontology rank generation schedule
    # 0 4 * * 1 - run once a week on Monday at 4:00AM
    @settings.cron_ontology_rank ||= '0 4 * * 1'
    # Ontologies report generation schedule
    # 30 1 * * * - run daily at 1:30AM
    @settings.cron_ontologies_report ||= "30 1 * * *"
    # Ontologies Report file location
    @settings.ontology_report_path ||= "../../reports/ontologies_report.json"

    # Ontologies Report file location
    @settings.graph_counts_report_path = "../../reports/graph_counts.json"

    # Index synchronizer schedule
    # 30 3 */2 * * - run every 2 days at 3:30AM
    @settings.cron_index_synchronizer ||= "30 3 */2 * *"
    # 30 2 * * * - run daily at 2:30AM
    @settings.cron_spam_deletion ||= "30 2 * * *"
    # OBOFoundry synchronization report schedule
    # 0 8 * * 1,2,3,4,5 - run daily Monday through Friday at 8:00AM
    @settings.cron_obofoundry_sync ||= "0 8 * * 1,2,3,4,5"
    # 00 3 * * * - run daily at 3:00AM
    @settings.cron_update_check ||= "00 3 * * *"
    # mgrep dictionary generation schedule
    # 30 3 * * * - run daily at 3:30AM
    @settings.cron_dictionary_generation_cron_job ||= "30 3 * * *"

    @settings.log_level ||= :info
    unless (@settings.log_path && File.exist?(@settings.log_path))
      log_dir = File.expand_path("../../../logs", __FILE__)
      FileUtils.mkdir_p(log_dir)
      @settings.log_path = "#{log_dir}/scheduler.log"
    end
    if File.exist?("/var/run/ncbo_cron")
      pid_path = File.expand_path("/var/run/ncbo_cron/ncbo_cron.pid", __FILE__)
    else
      pid_path = File.expand_path("../../../ncbo_cron.pid", __FILE__)
    end
    @settings.pid_path ||= pid_path

    # minutes between process queue checks (override seconds)
    @settings.minutes_between ||= 5
    # seconds between process queue checks
    @settings.seconds_between ||= nil

    ############## OntoPortal Appliance specific settings ########################
    # A config file that identifies the current version of Ontoportal
    @settings.versions_file_path = "/opt/ontoportal/virtual_appliance/deployment/versions"
    # An endpoint that checks for Ontoportal update availability
    @settings.update_check_endpoint_url = "https://updatecheck.ontoportal.org/latestversion"

    # Override defaults
    yield @settings if block_given?
  end
end
