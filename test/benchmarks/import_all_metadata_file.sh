#!/usr/bin/env bash
path_graphs_files=$1
profile=$2
set -e


if [ -z "$profile" ]; then
  echo "Usage: $0 <path to path_graphs_files> <profile>"
  exit 1
fi
echo "###########################################################################"
./test/benchmarks/start_ontoportal_services.sh "$profile"
./bin/migrations/import_metadata_graphs_to_store "$path_graphs_files" "$profile"
echo 'All metadata graphs imported successfully.'
echo "###########################################################################"

bundle exec ruby bin/migrations/compare_counts.rb "$path_graphs_files" "$profile"
