require 'logger'

# Scheduling/lock gems
require 'redis-lock'
require 'active_support/isolated_execution_state'
require 'rufus/scheduler'

module NcboCron
  class Scheduler
    LOCK_OWNER = "ncbo_cron".freeze

    ##
    # Schedule a job with redis-supported locking
    # options:
    #   life: length in seconds of the initial lock
    #   job_name: the scheduled job's name
    #   logger: a logger to track errors/debug output
    #   relock_period: seconds between lock extensions while the job runs (default: life - 15)
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
      relock_period   = options[:relock_period] || [lock_life - 15, 1].max
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
          redis.lock(job_name, life: lock_life, owner: LOCK_OWNER) do
            pid = fork do
              $0 = job_name # rename the process
              exit_status = 0
              begin
                logger.debug("#{job_name} -- Lock acquired"); logger.flush

                # Keep extending the lock while the job runs so that a job
                # outlasting lock_life isn't treated as stale by another host.
                start_relock_thread(job_name, redis_host, redis_port, lock_life, relock_period, logger)

                # Run the process if we have a job
                yield if block_given?
                process.call if process
              rescue SystemExit => e
                exit_status = e.status
              rescue Exception => e
                exit_status = 1
                backtrace = (e.backtrace || []).first(10).join("\n\t")
                logger.error("#{job_name} -- Job failed: #{e.class}: #{e.message}\n\t#{backtrace}")
              ensure
                logger.flush rescue nil
                Kernel.exit!(exit_status)
              end
            end
            logger.debug("#{job_name} -- running in pid #{pid}"); logger.flush
            _, status = Process.wait2(pid)
            unless status.success?
              logger.error("#{job_name} -- pid #{pid} exited with #{status.inspect}"); logger.flush
            end
          end
        rescue Redis::Lock::LockNotAcquired
          # Expected when another worker holds the lock; don't spam error logs.
          logger.debug("#{job_name} -- Lock not acquired"); logger.flush
        end
      end

      # Wait for scheduling (don't exit)
      scheduler.join
    end

    ##
    # Runs in the forked job process: every relock_period seconds, push the
    # lock's expiration out to now + lock_life. Uses its own Redis connection
    # rather than the parent's, and a Redis::Lock with the same key/owner as
    # the one acquired by the parent (redis-lock only extends a lock whose
    # owner matches). Stops if the lock can no longer be extended.
    def self.start_relock_thread(job_name, redis_host, redis_port, lock_life, relock_period, logger)
      Thread.new do
        begin
          lock = Redis::Lock.new(Redis.new(host: redis_host, port: redis_port),
                                 job_name, life: lock_life, owner: LOCK_OWNER)
          loop do
            sleep(relock_period)
            logger.debug("#{job_name} -- Re-locking for #{lock_life}s"); logger.flush
            lock.extend_life(lock_life)
          end
        rescue Redis::Lock::LockNotAcquired
          logger.error("#{job_name} -- Lost lock; could not extend it"); logger.flush
        rescue StandardError => e
          logger.error("#{job_name} -- Re-lock thread failed: #{e.class}: #{e.message}"); logger.flush
        end
      end
    end
  end
end
