#!/bin/bash
# sample script for running unit tests in docker.  This functionality should be moved to a rake task
#
# add config for unit testing
[ -f ../config/config.rb ] || cp ../config/config.test.rb ../config/config.rb
docker compose build

# wait-for-it is useful since solr container might not get ready quick enough for the unit tests
docker compose run --rm ruby bundle exec rake test TESTOPTS='-v'
#docker compose run --rm ruby-agraph bundle exec rake test TESTOPTS='-v'
#docker-compose run --rm ruby bundle exec rake test TESTOPTS='-v' TEST='./test/controllers/test_annotator_controller.rb'
docker compose kill
