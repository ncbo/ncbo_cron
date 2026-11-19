require_relative 'test_case'
# require_relative '../lib/ncbo_cron'
require 'securerandom'
require 'tempfile'

class TestScheduler < TestCase
  # Killing the thread blocked in scheduler.join doesn't stop the Rufus
  # scheduler itself; shut down any left running so tests don't leak jobs.
  def teardown
    Thread.list.map { |t| t[:rufus_scheduler] }.compact.uniq.each do |scheduler|
      scheduler.shutdown(:kill)
    end
    super
  end

  def test_scheduler
    begin
      logger = Logger.new($stdout)
      logger.level = Logger::ERROR
      job_name = "test_scheduled_job_locking_#{Process.pid}_#{SecureRandom.hex(4)}"
      options = {
        job_name: job_name,
        seconds_between: 1,
        redis_host: NcboCron.settings.redis_host,
        redis_port: NcboCron.settings.redis_port,
        logger: logger
      }

      # Create a simple TCPServer to listen from the fork
      require 'socket'
      listen_string = ''
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]

      socket_server = Thread.new do
        loop do
          session = server.accept
          listen_string << session.gets
        end
      end

      # Spawn a thread with a job that takes a while to finish
      job1_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options) do
          client = TCPSocket.new('127.0.0.1', port)
          client.puts("MESSAGE_SENT\n")
        end
      end

      sleep(5)
      finished_array = listen_string.split("\n")

      assert_operator 4, :<=, finished_array.length

      assert job1_thread.alive?
      job1_thread.kill
      job1_thread.join
      refute job1_thread.alive?
    ensure
      if defined?(job1_thread) && job1_thread.alive?
        job1_thread.kill
        job1_thread.join
      end
      if defined?(socket_server) && socket_server.alive?
        socket_server.kill
        socket_server.join
      end
      server.close if defined?(server) && !server.closed?
    end
  end

  def test_scheduler_locking
    begin
      job_name = "test_scheduled_job_locking_#{Process.pid}_#{SecureRandom.hex(4)}"
      options = {
        job_name: job_name,
        seconds_between: 5,
        redis_host: NcboCron.settings.redis_host,
        redis_port: NcboCron.settings.redis_port
      }

      # Create a simple TCPServer to listen from the fork
      require 'socket'
      listen_string = ''
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      socket_server = Thread.new do
        loop do
          session = server.accept
          listen_string << session.gets
        end
      end

      # Spawn a thread with a job that takes a while to finish
      job1_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options) do
          client = TCPSocket.new('127.0.0.1', port)
          client.puts("JOB1\n")
          sleep(60)
        end
      end

      # Wait for the lock to be acquired and the job to run
      sleep(10)

      # Spawn a second thread with the same name. This one shouldn't
      # be able to get a lock because of the long-running job above.
      job2_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options.merge(seconds_between: 1)) do
          client = TCPSocket.new('127.0.0.1', port)
          client.puts("JOB2\n")
          sleep(60)
        end
      end

      sleep(10)

      assert job1_thread.alive?
      assert job2_thread.alive?
      assert_includes listen_string, 'JOB1'
      refute_includes listen_string, 'JOB2'
      job1_thread.kill
      job1_thread.join
      refute job1_thread.alive?
      job2_thread.kill
      job2_thread.join
      refute job2_thread.alive?
    ensure
      if defined?(job1_thread)
        job1_thread.kill
        job1_thread.join
      end
      if defined?(job2_thread)
        job2_thread.kill
        job2_thread.join
      end
      if defined?(socket_server)
        socket_server.kill
        socket_server.join
      end
      server.close if defined?(server) && !server.closed?
    end
  end

  # A job that outlives its lock `life` must keep the lock by extending it,
  # otherwise another host would see it as stale and run the same job.
  def test_scheduler_extends_lock_life
    begin
      job_name = "test_scheduled_job_relock_#{Process.pid}_#{SecureRandom.hex(4)}"
      redis = Redis.new(host: NcboCron.settings.redis_host, port: NcboCron.settings.redis_port)
      lock_life = 3
      options = {
        job_name: job_name,
        seconds_between: 1,
        life: lock_life,
        relock_period: 1,
        redis_host: NcboCron.settings.redis_host,
        redis_port: NcboCron.settings.redis_port,
        logger: Logger.new(StringIO.new)
      }

      job_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options) { sleep(lock_life * 3) }
      end

      # Wait for the job to take the lock and remember the initial expiration
      initial_expire = nil
      40.times do
        initial_expire = redis.get("lock:expire:#{job_name}")
        break if initial_expire
        sleep(0.25)
      end
      refute_nil initial_expire, 'job never acquired the lock'

      # Run well past the original lock life
      sleep(lock_life * 2)

      current_expire = redis.get("lock:expire:#{job_name}").to_i
      assert_operator current_expire, :>, initial_expire.to_i, 'lock expiration was never extended'
      assert_operator current_expire, :>=, Time.now.to_i, 'lock is stale while the job is still running'

      # A competing worker must not be able to take the lock over as stale
      assert_raises(Redis::Lock::LockNotAcquired) do
        redis.lock(job_name, life: lock_life, owner: 'competing_host', acquire: 1) { flunk 'competitor acquired the lock' }
      end
    ensure
      if defined?(job_thread) && job_thread
        job_thread.kill
        job_thread.join
      end
      redis&.del("lock:owner:#{job_name}", "lock:expire:#{job_name}")
      redis&.close
    end
  end

  def test_scheduler_logs_job_failure
    begin
      job_name = "test_scheduled_job_failure_#{Process.pid}_#{SecureRandom.hex(4)}"
      log_file = Tempfile.new('scheduler_log')
      logger = Logger.new(log_file.path)
      logger.level = Logger::ERROR
      options = {
        job_name: job_name,
        seconds_between: 1,
        redis_host: NcboCron.settings.redis_host,
        redis_port: NcboCron.settings.redis_port,
        logger: logger
      }

      job_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options) { raise ArgumentError, 'boom from job' }
      end

      log = ''
      20.times do
        sleep(0.25)
        log = File.read(log_file.path)
        break if log.include?('exited with')
      end

      assert_includes log, "#{job_name} -- Job failed: ArgumentError: boom from job"
      assert_match(/test_scheduler\.rb:\d+/, log, 'backtrace not logged')
      assert_match(/#{job_name} -- pid \d+ exited with .*exit 1/, log)
    ensure
      if defined?(job_thread) && job_thread
        job_thread.kill
        job_thread.join
      end
      log_file&.close!
    end
  end
end
