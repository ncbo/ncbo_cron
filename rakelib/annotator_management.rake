# Rake tasks for managing Annotator Redis term caches.
# Allows switching between primary and alternate instances, purging the alternate cache,
# and retrieving the current cache prefix.

desc 'Annotator Utilities'
namespace :annotator do
  require 'bundler/setup'
  require_relative '../lib/ncbo_cron'

  config_exists = File.exist?(File.expand_path('../../config/config.rb', __FILE__))
  abort('Please create a config/config.rb file using the config/config.rb.sample as a template') unless config_exists

  require_relative '../config/config'
  require 'ostruct'

  def annotator_redis
    annotator = Annotator::Models::NcboAnnotator.new
    OpenStruct.new(
      annotator: annotator,
      cur_inst: annotator.redis_current_instance,
      alt_inst: annotator.redis_default_alternate_instance
    )
  end

  namespace :redis_instance do
    desc 'Get current Annotator redis terms cache prefix'
    task :get do
      redis = annotator_redis
      puts redis.cur_inst
    end

    desc 'Delete Annotator term cache from the alternate instance'
    # use with caution!!! useful for reducing memory/disk footprint
    task :purge_alternate do
      redis = annotator_redis
      puts "Cleared Annotator Redis alternate terms cache #{redis.alt_inst}"
      redis.annotator.delete_term_cache(redis.alt_inst)
    end

    desc 'Swap Annotator Redis term cache instance from primary to alternate'
    task :switch_to_alternate do
      redis = annotator_redis
      redis.annotator.redis_switch_instance
      puts "Annotator Redis terms cache instance has been switched to #{redis.alt_inst}"
    end
  end
end
