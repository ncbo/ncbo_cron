require 'minitest/unit'
MiniTest::Unit.autorun

require_relative '../lib/ncbo_cron'

class TestScheduler < MiniTest::Unit::TestCase
  def test_scheduler
    begin
      logger = Logger.new($stdout)
      logger.level = Logger::ERROR
      options = {
        job_name: "test_scheduled_job",
        seconds_between: 1,
        redis_host: NcboCron.settings.redis_host,
        redis_port: NcboCron.settings.redis_port,
        logger: logger
      }

      # Create a simple TCPServer to listen from the fork
      require 'socket'
      listen_string = ""
      port = Random.rand(55000..65535) # http://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers#Dynamic.2C_private_or_ephemeral_ports
      socket_server = Thread.new do
        server = TCPServer.new(port)
        loop {
          session = server.accept
          listen_string << session.gets
        }
      end

      # Spawn a thread with a job that takes a while to finish
      job1_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options) do
          client = TCPSocket.new('localhost', port)
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
    end
  end

  def test_scheduler_locking
    begin
      options = {
        job_name: "test_scheduled_job_locking",
        seconds_between: 5,
        redis_host: NcboCron.settings.redis_host,
        redis_port: NcboCron.settings.redis_port
      }

      # Create a simple TCPServer to listen from the fork
      require 'socket'
      listen_string = ""
      port = Random.rand(55000..65535) # http://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers#Dynamic.2C_private_or_ephemeral_ports
      socket_server = Thread.new do
        server = TCPServer.new(port)
        loop {
          session = server.accept
          listen_string << session.gets
        }
      end

      # Spawn a thread with a job that takes a while to finish
      job1_thread = Thread.new do
        NcboCron::Scheduler.scheduled_locking_job(options) do
          client = TCPSocket.new('localhost', port)
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
          client = TCPSocket.new('localhost', port)
          client.puts("JOB2\n")
          sleep(60)
        end
      end

      sleep(10)

      assert job1_thread.alive?
      assert job2_thread.alive?
      assert listen_string.include?("JOB1")
      refute listen_string.include?("JOB2")
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
    end
   end
end
