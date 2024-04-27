# -*- encoding: utf-8 -*-

Gem::Specification.new do |gem|
  gem.version       = "0.0.1"
  gem.authors       = [""]
  gem.email         = [""]
  gem.description   = %q{NCBO Cron Operations}
  gem.summary       = %q{}
  gem.homepage      = "https://github.com/ncbo/ncbo_cron"

  gem.files         = Dir['**/*']
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "ncbo_cron"
  gem.require_paths = ["lib"]

  gem.add_dependency("dante")
  gem.add_dependency('faraday', '~> 2')
  gem.add_dependency('faraday-follow_redirects', '~> 0')
  gem.add_dependency("goo")
  gem.add_dependency("google-analytics-data")
  gem.add_dependency("mlanett-redis-lock")
  gem.add_dependency("multi_json")
  gem.add_dependency("ncbo_annotator")
  gem.add_dependency("ontologies_linked_data")
  gem.add_dependency("redis")
  gem.add_dependency("rufus-scheduler", "~> 2.0.24")
end
