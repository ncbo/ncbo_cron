# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ncbo_cron is a multi-threaded scheduled task daemon for BioPortal/OntoPortal. It orchestrates ~15 independent jobs (ontology processing, indexing, analytics, pull, etc.) using Redis-backed distributed locking and Rufus Scheduler. Each job runs in a forked child process.

## Key Commands

```bash
# Run all tests
bundle exec rake test

# Run a single test file
bundle exec ruby -Itest test/test_scheduler.rb

# Run a single test method
bundle exec ruby -Itest test/test_scheduler.rb -n test_scheduler

# Run the main daemon
./bin/ncbo_cron

# Process a specific ontology
bundle exec ruby ./bin/ncbo_ontology_process -o ACRONYM

# Clear HTTP/Redis caches
bundle exec rake cache:clear
```

## Test Infrastructure

- **Framework**: Minitest with `minitest-hooks` for class-level setup/teardown
- **Base class**: `TestCase` in `test/test_case.rb` — clears triplestore in `before_all`
- **Safety**: Tests refuse to run against non-localhost backends without confirmation
- **CI**: Matrix tests across 4 triplestore backends (4store, AllegroGraph, Virtuoso, GraphDB) via `.ontoportal-testkit.yml`
- **Coverage**: `COVERAGE=true bundle exec rake test` for SimpleCov reports
- **Mocking**: `mocha` for stubs, `webmock` for HTTP (with `allow_net_connect!` enabled)

## Configuration

- Copy `config/config.rb.sample` → `config/config.rb` for local development
- Test config lives in `config/config.test.rb` — all services default to localhost
- All service endpoints are overridable via environment variables (GOO_HOST, REDIS_PORT, SOLR_TERM_SEARCH_URL, etc.)

## Architecture

### Sibling NCBO Projects (Gem Dependencies)

This project depends on several sibling repos under `~/dev/ncbo/`, loaded as git-sourced gems:

- **goo** — Triple store abstraction layer (SPARQL client, RDF operations, model persistence). Contains `Goo::SPARQL::Client` for uploading triples.
- **ontologies_linked_data** — Domain models (Ontology, Submission, Class, etc.) and submission processing pipeline (RDF generation, labeling, indexing, metrics)
- **ncbo_annotator** — Text annotation service using mgrep dictionary
- **sparql-client** — SPARQL 1.1 query/update client (fork of ruby-rdf/sparql-client)

When debugging issues that span projects, check the Gemfile for which branches are pinned.

### Processing Pipeline

The main flow for ontology processing:

1. `bin/ncbo_ontology_process` or queue via Redis → `OntologySubmissionParser`
2. `OntologySubmissionParser.process_queue_submissions()` reads from Redis `parseQueue`
3. Delegates to `submission.process_submission()` (in ontologies_linked_data)
4. Submission processing runs configurable actions: `process_rdf`, `generate_labels`, `extract_metadata`, `index_all_data`, `index_search`, `index_properties`, `run_metrics`, `process_annotator`, `diff`

### Scheduled Jobs

Defined in `bin/ncbo_cron`. Each job has an `enable_*` flag and `cron_*` schedule in config. Jobs include: submission queue processing, ontology pull, query warming, mapping counts, analytics (Google/Cloudflare), ranking, reporting, index sync, spam deletion, OBO Foundry sync.

### Key Modules

- `lib/ncbo_cron/scheduler.rb` — Redis-backed lock acquisition with periodic re-lock (60s interval)
- `lib/ncbo_cron/ontology_submission_parser.rb` — Queue consumer, dispatches processing actions
- `lib/ncbo_cron/ontology_pull.rb` — Downloads remote ontologies, creates submissions on change (MD5 comparison)
- `lib/ncbo_cron/ontology_helper.rb` — Shared helpers, action constants, file download utilities

### External Services Required

- **Triplestore** (4store/Virtuoso/AllegroGraph/GraphDB) — RDF storage
- **Solr** — Term and property search indexing
- **Redis** — Job locking, submission queue, query/HTTP caching
- **mgrep** — Text annotation dictionary service
