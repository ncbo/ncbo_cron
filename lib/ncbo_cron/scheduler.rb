require 'logger'

# Scheduling/lock gems
require 'redis-lock'
require 'active_support/isolated_execution_state'
require 'rufus/scheduler'

module NcboCron
  class Scheduler
    ##
    # Schedule a job with redis-supported locking
    # options:
    #   life: length in seconds of the initial lock
    #   job_name: the scheduled job's name
    #   logger: a logger to track errors/debug output
    #   relock_preiod: number of seconds to re-lock for, holds lock during job
    #   redis_host: hostname where redis lock will be performed
    #   redis_port: port for redis host
    #   process: a proc that can be run
    #   minutes_between: how many minutes between job runs (default: 5)
    #   seconds_between: how many seconds between job runs (priority given to minutes if both passed)
    # block: block of code that is the scheduled job
    def self.scheduled_locking_job(options = {}, &block)
      lock_life       = options[:life] || 10*60
      job_name        = options[:job_name] || "ncbo_cron"
      logger          = options[:logger] || Logger.new($stdout)
      relock_period   = options[:relock_period] || lock_life - 15
      redis_host      = options[:redis_host] || "localhost"
      redis_port      = options[:redis_port] || 6379
      process         = options[:process]
      minutes_between = options[:minutes_between]
      seconds_between = options[:seconds_between]
      scheduler_type  = options[:scheduler_type] || :every
      cron_schedule   = options[:cron_schedule]

      if scheduler_type == :every
        # Minutes/seconds string prep
        # Rufus expects explicit units; defaulting to seconds keeps intent clear.
        interval = "#{seconds_between}s" if seconds_between
        interval = "#{minutes_between}m" if minutes_between
        interval = "5m" unless interval
      end

      if scheduler_type == :cron
        interval = cron_schedule
      end

      redis = Redis.new(host: redis_host, port: redis_port)
      scheduler = Rufus::Scheduler.new(thread_name: job_name)

      scheduler.send(scheduler_type, interval, {:allow_overlapping => false}) do
        begin
          redis.lock(job_name, life: lock_life, owner: "ncbo_cron") do
            pid = fork do
              $0 = job_name # rename the process
              begin
                logger.debug("#{job_name} -- Lock acquired"); logger.flush

                # Spawn a thread to re-acquire the lock every 60 seconds
                Thread.new do
                  sleep(relock_period) do
                    logger.debug("Re-locking for #{lock_life}")
                    lock.extend_life(lock_life)
                  end
                end

                # Run the process if we have a job
                yield if block_given?
                process.call if process
              ensure
                Kernel.exit!
              end
            end
            logger.debug("#{job_name} -- running in pid #{pid}"); logger.flush
            Process.wait(pid)
          end
        rescue Redis::Lock::LockNotAcquired
          # Expected when another worker holds the lock; don't spam error logs.
          logger.debug("#{job_name} -- Lock not acquired"); logger.flush
        end
      end

      # Wait for scheduling (don't exit)
      scheduler.join
    end
  end
end
