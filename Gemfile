source 'https://rubygems.org'

gemspec

gem 'ffi'

# This is needed temporarily to pull the Google Universal Analytics (UA)
# data and store it in a file. See (bin/generate_ua_analytics_file.rb)
# The ability to pull this data from Google will cease on July 1, 2024
gem "google-apis-analytics_v3"

gem 'activesupport'
gem 'google-analytics-data'
gem 'multi_json'
gem 'oj', '~> 3.0'
gem 'parseconfig'
gem 'pony'
gem 'pry'
gem 'rake'
gem 'request_store'
gem 'parallel'
gem 'json-ld'
gem 'redis'
gem 'rest-client'
gem 'sys-proctable'

# Monitoring
gem 'cube-ruby', require: 'cube'

# NCBO
gem 'goo', github: 'ncbo/goo', branch: 'ontoportal-lirmm-development'
gem 'ncbo_annotator', github: 'ncbo/ncbo_annotator', branch: 'chore/ruby3.2-minitest6-compat'
gem 'ontologies_linked_data', github: 'ncbo/ontologies_linked_data', branch: 'chore/ontoportal-lirmm-goo-compat'
gem 'sparql-client', github: 'ncbo/sparql-client', branch: 'ontoportal-lirmm-development'

group :development do
  gem 'rubocop', require: false
end

group :test do
  gem 'email_spec'
  gem 'minitest'
  gem 'minitest-hooks'
  gem 'minitest-reporters'
  gem 'mocha', '~> 2.7'
  gem 'ontoportal_testkit', github: 'alexskr/ontoportal_testkit', branch: 'main'
  gem 'simplecov'
  gem 'simplecov-cobertura' # for codecov.io
  gem 'webmock', '~> 3.25'
  gem 'webrick'
end
