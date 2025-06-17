# frozen_string_literal: true

require_relative 'test_case'

class CloudflareAnalyticsTest < TestCase
  def setup
    @log_output = StringIO.new
    @logger = Logger.new(@log_output)
    @analytics = NcboCron::Models::CloudflareAnalytics.new(@logger)

    @temp_data_file = Tempfile.new('test_cf_data')
    @temp_data_file.write('{"TEST_ONT":{"2024":{"6":42}}}')
    @temp_data_file.close

    NcboCron.settings.stubs(:cloudflare_zone_tag).returns('test-zone-123')
    NcboCron.settings.stubs(:cloudflare_api_token).returns('test-token-456')
  end

  def test_update_visit_data
    json_data = {}
    @analytics.update_visit_data(json_data, 'NEW_ONT', 100, '2024', '6')

    assert_equal 100, json_data['NEW_ONT']['2024']['6']
  end

  def test_update_visit_data_accumulates
    json_data = { 'EXISTING_ONT' => { '2024' => { '6' => 50 } } }
    @analytics.update_visit_data(json_data, 'EXISTING_ONT', 25, '2024', '6')

    assert_equal 75, json_data['EXISTING_ONT']['2024']['6']
  end

  def test_extract_visits_and_budget_success
    api_response = {
      'data' => {
        'viewer' => {
          'budget' => 1000,
          'zones' => [{
            'httpRequestsAdaptiveGroups' => [{
              'sum' => { 'visits' => 150 }
            }]
          }]
        },
        'cost' => 10
      }
    }

    result = @analytics.extract_visits_and_budget(api_response)

    assert_equal 150, result[:visits]
    assert_equal 1000, result[:budget]
    assert_equal 10, result[:cost]
    assert_equal 100, result[:remaining_queries]
  end

  def test_extract_visits_and_budget_no_visits
    api_response = {
      'data' => {
        'viewer' => {
          'budget' => 1000,
          'zones' => [{
            'httpRequestsAdaptiveGroups' => [{}]
          }]
        },
        'cost' => 10
      }
    }

    result = @analytics.extract_visits_and_budget(api_response)
    assert_equal 0, result[:visits]
  end

  def test_extract_visits_and_budget_missing_zones
    api_response = {
      'data' => {
        'viewer' => {
          'budget' => 1000,
          'zones' => []
        }
      }
    }

    error = assert_raises(RuntimeError) do
      @analytics.extract_visits_and_budget(api_response)
    end
    assert_includes error.message, 'API response missing expected zones data'
  end

  # =============================================================================
  # Date range tests
  # =============================================================================

  def test_generate_date_range
    travel_to = Date.new(2025, 6, 1)
    Date.stubs(:today).returns(travel_to)

    start_iso, end_iso = @analytics.generate_date_range

    assert_equal '2025-05-31T00:00:00Z', start_iso
    assert_equal '2025-06-01T00:00:00Z', end_iso
  end

  def test_generate_date_range_with_custom_date
    custom_date = Date.new(2024, 3, 6)
    start_iso, end_iso = @analytics.generate_date_range(custom_date)

    assert_equal '2024-03-05T00:00:00Z', start_iso
    assert_equal '2024-03-06T00:00:00Z', end_iso
  end

  def test_generate_date_range_month_boundary
    # Test crossing month boundary
    travel_to = Date.new(2024, 3, 1) # March 1st
    Date.stubs(:today).returns(travel_to)

    start_iso, end_iso = @analytics.generate_date_range

    assert_equal '2024-02-29T00:00:00Z', start_iso # Leap year
    assert_equal '2024-03-01T00:00:00Z', end_iso
  end

  def test_generate_date_range_year_boundary
    # Test crossing year boundary
    travel_to = Date.new(2025, 1, 1) # January 1st
    Date.stubs(:today).returns(travel_to)

    start_iso, end_iso = @analytics.generate_date_range

    assert_equal '2024-12-31T00:00:00Z', start_iso
    assert_equal '2025-01-01T00:00:00Z', end_iso
  end

  # =============================================================================
  # GraphQL request tests
  # =============================================================================

  def test_build_query
    query = @analytics.build_query('TEST_ONT',
                                   start_date: '2024-06-11T00:00:00Z',
                                   end_date: '2024-06-12T00:00:00Z')

    assert_includes query, 'clientRequestPath: "/ontologies/TEST_ONT"'
    assert_includes query, 'datetime_geq: "2024-06-11T00:00:00Z"'
    assert_includes query, 'datetime_lt: "2024-06-12T00:00:00Z"'
    assert_includes query, 'zoneTag: "test-zone-123"'
    assert_match(/sum\s*{\s*visits\s*}/, query)
  end

  def test_fetch_graphql_success
    response_body = {
      'data' => {
        'viewer' => {
          'zones' => [{ 'httpRequestsAdaptiveGroups' => [{ 'sum' => { 'visits' => 42 } }] }]
        }
      }
    }.to_json

    stub_request(:post, 'https://api.cloudflare.com/client/v4/graphql')
      .with(
        body: { query: 'test query' }.to_json,
        headers: { 'Authorization' => 'Bearer test-token-456', 'Content-Type' => 'application/json' }
      )
      .to_return(status: 200, body: response_body)

    result = @analytics.fetch_graphql('test query')
    assert_equal 42, result.dig('data', 'viewer', 'zones', 0, 'httpRequestsAdaptiveGroups', 0, 'sum', 'visits')
  end

  def test_fetch_graphql_http_error
    stub_request(:post, 'https://api.cloudflare.com/client/v4/graphql')
      .to_return(status: 500, body: 'Internal Server Error')

    result = @analytics.fetch_graphql('test query')

    assert_nil result
    assert_includes @log_output.string, 'Faraday HTTP error'
  end

  def test_fetch_graphql_json_parse_error
    stub_request(:post, 'https://api.cloudflare.com/client/v4/graphql')
      .to_return(status: 200, body: 'invalid json{')

    result = @analytics.fetch_graphql('test query')

    assert_nil result
    assert_includes @log_output.string, 'Failed to parse JSON response'
  end

  # =============================================================================
  # File operations - write_updated_data tests
  # =============================================================================

  def test_write_updated_data_creates_backup
    json_data = { 'TEST_ONT' => { '2024' => { '6' => 100 } } }

    existing_file = Tempfile.new('existing_data')
    existing_file.write('{"old": "data"}')
    existing_file.close

    NcboCron.settings.stubs(:cloudflare_data_file).returns(existing_file.path)

    # Mock timestamp for predictable backup filename
    Time.stubs(:now).returns(Time.new(2024, 6, 12, 14, 30, 45))

    @analytics.send(:write_updated_data, json_data)

    # Check that backup was created
    backup_path = "#{existing_file.path}.backup_20240612_143045"
    assert File.exist?(backup_path), 'Backup file should exist'
    assert_equal '{"old": "data"}', File.read(backup_path)

    # Check that main file was updated
    assert_equal json_data.to_json, File.read(existing_file.path)

    log_content = @log_output.string
    assert_includes log_content, "Creating backup: #{backup_path}"
    assert_includes log_content, 'Backup created successfully'

    File.unlink(backup_path) if File.exist?(backup_path)
    existing_file.unlink
  end

  def test_write_updated_data_handles_file_write_error
    json_data = { 'TEST_ONT' => { '2024' => { '6' => 100 } } }

    invalid_path = '/invalid/path/that/does/not/exist/data.json'
    NcboCron.settings.stubs(:cloudflare_data_file).returns(invalid_path)

    assert_raises(StandardError) do
      @analytics.send(:write_updated_data, json_data)
    end

    log_content = @log_output.string
    assert_includes log_content, 'File write failed:'
  end

  # =============================================================================
  # Redis operations tests
  # =============================================================================

  def test_write_to_redis_connection_error
    json_data = { 'TEST_ONT' => { '2024' => { '6' => 100 } } }

    Redis.expects(:new).raises(Redis::CannotConnectError.new('Connection refused'))

    LinkedData.settings.stubs(:ontology_analytics_redis_host).returns('localhost')
    LinkedData.settings.stubs(:ontology_analytics_redis_port).returns(6379)

    error = assert_raises(RuntimeError) do
      @analytics.send(:write_to_redis, json_data)
    end

    assert_includes error.message, 'Failed to write to Redis: Connection refused'

    log_content = @log_output.string
    assert_includes log_content, 'Redis operation failed: Connection refused'
  end

  def test_write_to_redis_unexpected_error
    json_data = { 'TEST_ONT' => { '2024' => { '6' => 100 } } }

    Redis.expects(:new).raises(StandardError.new('Unexpected error'))

    LinkedData.settings.stubs(:ontology_analytics_redis_host).returns('localhost')
    LinkedData.settings.stubs(:ontology_analytics_redis_port).returns(6379)

    error = assert_raises(StandardError) do
      @analytics.send(:write_to_redis, json_data)
    end

    assert_equal 'Unexpected error', error.message

    log_content = @log_output.string
    assert_includes log_content, 'Unexpected error writing to Redis: StandardError - Unexpected error'
  end

  def test_write_to_redis_success
    json_data = { 'TEST_ONT' => { '2024' => { '6' => 100 } } }

    mock_redis = mock('redis')
    mock_redis.expects(:set).with('cloudflare_analytics', Marshal.dump(json_data))
    mock_redis.expects(:close)

    Redis.expects(:new).with(
      host: LinkedData.settings.ontology_analytics_redis_host,
      port: LinkedData.settings.ontology_analytics_redis_port
    ).returns(mock_redis)

    LinkedData.settings.stubs(:ontology_analytics_redis_host).returns('localhost')
    LinkedData.settings.stubs(:ontology_analytics_redis_port).returns(6379)

    @analytics.send(:write_to_redis, json_data)

    log_content = @log_output.string
    assert_includes log_content, 'Writing data to Redis...'
    assert_includes log_content, 'Successfully wrote data to Redis'
    assert_includes log_content, 'Redis connection closed'
  end
end
