# Benchmarks
## Import all AgroPortal metadata
test/benchmarks/import_all_metadata_file.sh ./processed_files gb
ruby test/benchmarks/run_metadata_benchs.rb gb

## Parse INRAETHES and do ontoportal operations
ruby test/benchmarks/parse_and_do_ontoportal_operations.rb INRAETHES fs 

## Parse ITIS and do ontoportal operations
ruby test/benchmarks/parse_and_do_ontoportal_operations.rb ITIS fs api_key https://data.biodivportal.gfbio.dev 
