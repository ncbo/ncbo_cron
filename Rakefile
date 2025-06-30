require 'rake/testtask'

task default: :test

Rake::TestTask.new do |t|
  t.libs = []
  t.test_files = FileList['test/**/test*.rb', 'test/**/*_test.rb']
  t.ruby_opts = ['-W1']
end

def clear_cache
  require 'ontologies_linked_data'
  require 'ncbo_annotator'
  require 'ncbo_cron'
  require 'redis'
  require_relative 'config/config'
  LinkedData::HTTPCache.invalidate_all
  redis = Redis.new(host: LinkedData.settings.goo_redis_host, port: LinkedData.settings.goo_redis_port, timeout: 30)
  redis.flushdb
  `rm -rf cache/`
end

namespace :cache do
  desc 'Clear HTTP cache (redis and Rack::Cache)'
  task :clear do
    clear_cache
  end
end
