require_relative 'test_case'
require 'stringio'

class TestOntologyRankPropagation < TestCase
  def test_run_propagates_rank_to_solr_after_redis_write
    rank_job = NcboCron::Models::OntologyRank.new(Logger.new(StringIO.new))

    # Isolate from analytics/UMLS and Redis: stub the computation and the store.
    rank_job.stubs(:rank_ontologies).returns({ 'BRO' => { bioportalScore: 0.5, umlsScore: 0.0 } })
    fake_redis = mock('redis')
    fake_redis.stubs(:set)
    Redis.stubs(:new).returns(fake_redis)

    # The propagation step must run exactly once.
    LinkedData::Services::RankSolrPropagator.any_instance.expects(:propagate).once.returns(1)

    rank_job.run
  end
end
