source 'https://rubygems.org'

gemspec

gem 'ffi'

# This is needed temporarily to pull the Google Universal Analytics (UA)
# data and store it in a file. See (bin/generate_ua_analytics_file.rb)
# The ability to pull this data from Google will cease on July 1, 2024
gem "google-apis-analytics_v3"

gem 'google-analytics-data'
gem 'multi_json'
gem 'oj', '~> 3.0'
gem 'parseconfig'
gem 'pony'
gem 'pry'
gem 'rake'
gem 'redis'
gem 'rest-client'
gem 'sys-proctable'

# Monitoring
gem 'cube-ruby', require: 'cube'

# NCBO
gem 'goo', github: 'ncbo/goo', branch: 'master'
gem 'ncbo_annotator', github: 'ncbo/ncbo_annotator', branch: 'master'
gem 'ontologies_linked_data', github: 'ncbo/ontologies_linked_data', branch: 'master'
gem 'sparql-client', github: 'ncbo/sparql-client', branch: 'master'

group :development do
  gem 'rubocop', require: false
end

group :test do
  gem 'email_spec'
  gem 'minitest', '< 5.0'
  gem 'simplecov'
  gem 'simplecov-cobertura' # for codecov.io
  gem 'test-unit-minitest'
  gem 'webrick'
end
