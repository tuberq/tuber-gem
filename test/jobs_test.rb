# frozen_string_literal: true

# test/jobs_test.rb

require File.expand_path('../test_helper', __FILE__)

describe Tuber::Jobs do
  before do
    @beanstalk = Tuber.new(tuber_address)
    @jobs = Tuber::Jobs.new(@beanstalk)
    @tube = @beanstalk.tubes.find('baz')
  end

  describe "for #find" do
    before do
      @time = Time.now.to_i
      @tube.put("foo find #{@time}")
      @job = @tube.peek(:ready)
    end

    it "should return job from id" do
      assert_equal "foo find #{@time}", @jobs.find(@job.id).body
    end

    it "should return job using peek" do
      assert_equal "foo find #{@time}", @jobs.find(@job.id).body
    end

    it "should return job using hash syntax" do
      assert_equal "foo find #{@time}", @jobs.find(@job.id).body
    end

    it "should return nil for invalid negative id" do
      assert_nil @jobs.find(10000) 
    end

    it "should return nil for invalid negative id" do
      assert_raises(Tuber::BadFormatError) { @jobs.find(-1) }
    end
  end # find

  describe "for #touch_all" do
    before do
      require_tuber!
      @touch_tube = @beanstalk.tubes.find('touch_all_tube')
      @beanstalk.tubes.watch! 'touch_all_tube'
    end

    after do
      cleanup_tubes!(['touch_all_tube'], @beanstalk)
    end

    it "should return 0 when no jobs are held" do
      assert_equal 0, @beanstalk.jobs.touch_all
    end

    it "should count every job held by the connection" do
      3.times { |i| @touch_tube.put "touch all #{i}", :ttr => 5 }
      jobs = @beanstalk.tubes.reserve_batch(3)
      assert_equal 3, jobs.size
      assert_equal 3, @beanstalk.jobs.touch_all
      jobs.each(&:delete)
    end

    it "should exclude jobs the worker no longer holds" do
      2.times { |i| @touch_tube.put "touch all drop #{i}", :ttr => 5 }
      jobs = @beanstalk.tubes.reserve_batch(2)
      jobs.first.delete
      assert_equal 1, @beanstalk.jobs.touch_all
      jobs.last.delete
      assert_equal 0, @beanstalk.jobs.touch_all
    end

    it "should extend the ttr of held jobs" do
      @touch_tube.put "touch all ttr", :ttr => 3
      job = @beanstalk.tubes.reserve
      sleep 2
      assert_equal 1, @beanstalk.jobs.touch_all
      sleep 2
      assert_equal 'reserved', job.stats.state
      job.delete
    end
  end # touch_all

  describe "for #register!" do
    before do
      $foo = 0
      @jobs.register('tube', :retry_on => [Timeout::Error]) do |job|
        $foo += 1
      end
    end

    it "should store processor" do
      assert_equal 'tube', @jobs.processors.keys.first
      assert_equal [Timeout::Error], @jobs.processors.values.first[:retry_on]
    end

    it "should store block for 'tube'" do
      @jobs.processors['tube'][:block].call nil
      assert_equal 1, $foo
    end
  end # register!

  describe "for process!" do
    before do
      $foo = []

      @jobs.register('tube_success', :retry_on => [Timeout::Error]) do |job|
        # p job.body
        $foo << job.body
        raise Tuber::AbortProcessingError if job.body =~ /abort/
      end

      @jobs.register('tube_release', :retry_on => [Timeout::Error], :max_retries => 2) do |job|
        $foo << job.body
        raise Timeout::Error
      end

      @jobs.register('tube_buried') do |job|
        $foo << job.body
        raise RuntimeError
      end

      cleanup_tubes!(['tube_success', 'tube_release', 'tube_buried'])

      @beanstalk.tubes.find('tube_success').put("success abort", :pri => 2**31 + 1)
      @beanstalk.tubes.find('tube_success').put("success 2", :pri => 1)
      @beanstalk.tubes.find('tube_release').put("released")
      @beanstalk.tubes.find('tube_buried').put("buried")

      @jobs.process!(:release_delay => 0)
    end

    it "should process all jobs" do
      assert_equal ['success 2', 'released', 'released', 'released', 'buried', 'success abort'], $foo
    end

    it "should clear successful_jobs" do
      assert_equal 0, @beanstalk.tubes.find('tube_success').stats.current_jobs_ready
      assert_equal 1, @beanstalk.tubes.find('tube_success').stats.current_jobs_buried
      assert_equal 0, @beanstalk.tubes.find('tube_success').stats.current_jobs_reserved
    end

    it "should retry release jobs 2 times" do
      assert_equal 2, @beanstalk.tubes.find('tube_release').peek(:buried).stats.releases
    end

    it "should bury unexpected exception" do
      assert_equal 1, @beanstalk.tubes.find('tube_buried').stats.current_jobs_buried
    end
  end # for_process!

  # Each command is a round trip to the server, so process! should send only
  # the ones it needs. Commands before the reserve (watch, ignore) are set-up.
  describe "for process! round trips" do
    before do
      cleanup_tubes!(['tube_trips'])
      @trips = @beanstalk.tubes.find('tube_trips')
      @ids = []
    end

    def commands_from_reserve(sent)
      sent.drop_while { |command| command != 'reserve' }
    end

    it "should send reserve, stats-job and delete for a successful job" do
      @jobs.register('tube_trips') { |job| @ids << job.id; @jobs.stop! }
      @trips.put "trips success"
      sent = record_commands
      @jobs.process!
      id = @ids.first
      assert_equal ['reserve', "stats-job #{id}", "delete #{id}"], commands_from_reserve(sent)
    end

    it "should check stats once before releasing a job for retry" do
      @jobs.register('tube_trips', :retry_on => [Timeout::Error]) do |job|
        @ids << job.id
        @jobs.stop!
        raise Timeout::Error
      end
      @trips.put "trips retry", :pri => 100
      sent = record_commands
      @jobs.process!(:release_delay => 0)
      id = @ids.first
      assert_equal ['reserve', "stats-job #{id}", "stats-job #{id}", "release #{id} 100 0"],
        commands_from_reserve(sent)
      assert_equal 1, @trips.stats.current_jobs_ready
    end

    it "should not check on a job it has just buried" do
      @jobs.register('tube_trips') do |job|
        @ids << job.id
        @jobs.stop!
        raise RuntimeError
      end
      @trips.put "trips bury", :pri => 100
      sent = record_commands
      @jobs.process!
      id = @ids.first
      assert_equal ['reserve', "stats-job #{id}", "stats-job #{id}", "bury #{id} 100"],
        commands_from_reserve(sent)
      assert_equal 1, @trips.stats.current_jobs_buried
    end
  end # process! round trips

  # A handler may settle its own job: release it for a retry, bury it, or
  # delete it. process! must leave the job as the handler left it.
  describe "for process! with a handler that settles its job" do
    before do
      cleanup_tubes!(['tube_settle'])
      @settle = @beanstalk.tubes.find('tube_settle')
    end

    it "should keep a job the handler released" do
      @jobs.register('tube_settle') { |job| job.release(:delay => 0); @jobs.stop! }
      @settle.put "settle release"
      @jobs.process!
      refute_nil @settle.peek(:ready), "the released job was deleted"
    end

    it "should keep a job the handler released with a delay" do
      @jobs.register('tube_settle') { |job| job.release(:delay => 30); @jobs.stop! }
      @settle.put "settle release delayed"
      @jobs.process!
      refute_nil @settle.peek(:delayed), "the delayed job was deleted"
    end

    it "should keep a job the handler buried" do
      @jobs.register('tube_settle') { |job| job.bury; @jobs.stop! }
      @settle.put "settle bury"
      @jobs.process!
      refute_nil @settle.peek(:buried), "the buried job was deleted"
    end

    it "should stop without deleting a job the handler deleted" do
      # A loop that never stops is left blocked in reserve. Run it on its own
      # connection, so teardown isn't queued behind that reserve.
      worker = Tuber.new(tuber_address)
      jobs = Tuber::Jobs.new(worker)
      ids = []
      jobs.register('tube_settle') { |job| ids << job.id; job.delete; jobs.stop! }
      @settle.put "settle delete"
      sent = record_commands(worker)
      begin
        Timeout.timeout(5) { jobs.process! }
      ensure
        worker.close
      end
      id = ids.first
      assert_equal ['reserve', "stats-job #{id}", "delete #{id}"],
        sent.drop_while { |command| command != 'reserve' }
    end
  end # process! with a handler that settles its job
end # Tuber::Jobs
