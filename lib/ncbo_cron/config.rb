require 'ostruct'

module NcboCron
  extend self
  attr_reader :settings

  @settings = OpenStruct.new
  @settings_run = false
  def config(&block)
    return if @settings_run

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
    @settings.enable_warmq ||= true
    @settings.enable_mapping_counts ||= true
    # enable ontology analytics
    @settings.enable_ontology_analytics ||= true
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

    # UMLS auto-pull
    @settings.pull_umls_url ||= ""
    @settings.enable_pull_umls ||= false
    @settings.enable_obofoundry_sync ||= true

    # Schedulues
    @settings.cron_schedule ||= "30 */4 * * *"
    # Pull schedule
    @settings.pull_schedule ||= "00 18 * * *"
    # Delete class graphs of archive submissions
    @settings.cron_flush ||= "00 22 * * 2"
    # Warmup long time running queries
    @settings.cron_warmq ||= "00 */3 * * *"
    # Create mapping counts schedule
    # 30 0 * * 6 - run once per week on Saturday at 12:30AM
    @settings.cron_mapping_counts ||= "30 0 * * 6"
    # Ontology analytics refresh schedule
    # 15 0 * * 1 - run once a week on Monday at 12:15AM
    @settings.cron_ontology_analytics ||= "15 0 * * 1"
    # Ontologies report generation schedule
    # 30 1 * * * - run daily at 1:30AM
    @settings.cron_ontologies_report ||= "30 1 * * *"
    # Ontologies Report file location
    @settings.ontology_report_path = "../../reports/ontologies_report.json"
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
    @settings.log_dir  ||= nil          # let caller provide it
    @settings.log_path ||= nil          # will build it later

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

    # ── choose defaults *after* user input ───────────────────────────────
    @settings.log_dir  ||= File.expand_path("log", Dir.pwd)
    @settings.log_path ||= File.join(@settings.log_dir, "scheduler.log")
    @settings.pid_path ||= File.expand_path("ncbo_cron.pid", Dir.pwd)

    @settings_run = true
  end
end
