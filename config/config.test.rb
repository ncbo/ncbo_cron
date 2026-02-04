# This file is designed to be used for unit testing with docker-compose

GOO_BACKEND_NAME      = ENV.include?("GOO_BACKEND_NAME")      ? ENV["GOO_BACKEND_NAME"]      : "4store"
GOO_HOST              = ENV.include?("GOO_HOST")              ? ENV["GOO_HOST"]              : "localhost"
GOO_PATH_DATA         = ENV.include?("GOO_PATH_DATA")         ? ENV["GOO_PATH_DATA"]         : "/data/"
GOO_PATH_QUERY        = ENV.include?("GOO_PATH_QUERY")        ? ENV["GOO_PATH_QUERY"]        : "/sparql/"
GOO_PATH_UPDATE       = ENV.include?("GOO_PATH_UPDATE")       ? ENV["GOO_PATH_UPDATE"]       : "/update/"
GOO_PORT              = ENV.include?("GOO_PORT")              ? ENV["GOO_PORT"]              : 9000
MGREP_HOST            = ENV.include?("MGREP_HOST")            ? ENV["MGREP_HOST"]            : "localhost"
MGREP_PORT            = ENV.include?("MGREP_PORT")            ? ENV["MGREP_PORT"]            : 55555
MGREP_DICT_PATH       = ENV.include?("MGREP_DICT_PATH")       ? ENV["MGREP_DICT_PATH"]       : "./test/data/dictionary.txt"
REDIS_GOO_CACHE_HOST  = ENV.include?("REDIS_GOO_CACHE_HOST")  ? ENV["REDIS_GOO_CACHE_HOST"]  : "localhost"
REDIS_HTTP_CACHE_HOST = ENV.include?("REDIS_HTTP_CACHE_HOST") ? ENV["REDIS_HTTP_CACHE_HOST"] : "localhost"
REDIS_PERSISTENT_HOST = ENV.include?("REDIS_PERSISTENT_HOST") ? ENV["REDIS_PERSISTENT_HOST"] : "localhost"
REDIS_PORT            = ENV.include?("REDIS_PORT")            ? ENV["REDIS_PORT"]            : 6379
REPORT_PATH           = ENV.include?("REPORT_PATH")           ? ENV["REPORT_PATH"]           : "./test/tmp/ontologies_report.json"
REPOSITORY_FOLDER     = ENV.include?("REPOSITORY_FOLDER")     ? ENV["REPOSITORY_FOLDER"]     : "./test/data/ontology_files/repo"
REST_URL_PREFIX       = ENV.include?("REST_URL_PREFIX")       ? ENV["REST_URL_PREFIX"]       : "http://localhost:9393"
SOLR_PROP_SEARCH_URL  = ENV.include?("SOLR_PROP_SEARCH_URL")  ? ENV["SOLR_PROP_SEARCH_URL"]  : "http://localhost:8983/solr"
SOLR_TERM_SEARCH_URL  = ENV.include?("SOLR_TERM_SEARCH_URL")  ? ENV["SOLR_TERM_SEARCH_URL"]  : "http://localhost:8983/solr"

LinkedData.config do |config|
  config.goo_backend_name              = GOO_BACKEND_NAME.to_s
  config.goo_host                      = GOO_HOST.to_s
  config.goo_port                      = GOO_PORT.to_i
  config.goo_path_query                = GOO_PATH_QUERY.to_s
  config.goo_path_data                 = GOO_PATH_DATA.to_s
  config.goo_path_update               = GOO_PATH_UPDATE.to_s
  config.goo_redis_host                = REDIS_GOO_CACHE_HOST.to_s
  config.goo_redis_port                = REDIS_PORT.to_i
  config.http_redis_host               = REDIS_HTTP_CACHE_HOST.to_s
  config.http_redis_port               = REDIS_PORT.to_i
  config.ontology_analytics_redis_host = REDIS_PERSISTENT_HOST.to_s
  config.ontology_analytics_redis_port = REDIS_PORT.to_i
  config.repository_folder             = REPOSITORY_FOLDER.to_s
  config.search_server_url             = SOLR_TERM_SEARCH_URL.to_s
  config.property_search_server_url    = SOLR_PROP_SEARCH_URL.to_s
#  config.replace_url_prefix            = false
#  config.rest_url_prefix               = REST_URL_PREFIX.to_s
  # Email notifications.
  config.enable_notifications    = true
  config.email_sender            = "sender@domain.com" # Default sender for emails
  config.email_override          = "test@domain.com" # By default, all email gets sent here.  Disable with email_override_disable.
  config.smtp_host               = "smtp-unencrypted.stanford.edu"
  config.smtp_user               = nil
  config.smtp_password           = nil
  config.smtp_auth_type          = :none
  config.smtp_domain             = "localhost.localhost"
end

Annotator.config do |config|
  config.annotator_redis_host  = REDIS_PERSISTENT_HOST.to_s
  config.annotator_redis_port  = REDIS_PORT.to_i
  config.mgrep_host            = MGREP_HOST.to_s
  config.mgrep_port            = MGREP_PORT.to_i
  config.mgrep_dictionary_file = MGREP_DICT_PATH.to_s
end

# LinkedData::OntologiesAPI.config do |config|
#   config.http_redis_host = REDIS_HTTP_CACHE_HOST.to_s
#   config.http_redis_port = REDIS_PORT.to_i
# end
#
NcboCron.config do |config|
  config.daemonize  = false
  config.redis_host = REDIS_PERSISTENT_HOST.to_s
  config.redis_port = REDIS_PORT.to_i
  config.ontology_report_path = REPORT_PATH
end
