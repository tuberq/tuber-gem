# frozen_string_literal: true

# test/tube_test.rb

require File.expand_path('../test_helper', __FILE__)

describe Tuber::Tube do
  before do
    @beanstalk = Tuber.new(tuber_address)
    @tube = Tuber::Tube.new(@beanstalk, 'baz')
  end

  describe "for #put" do
    before do
      @time = Time.now.to_i
    end

    it "should insert a job" do
      @tube.put "bar put #{@time}"
      assert_equal "bar put #{@time}", @tube.peek(:ready).body
      assert_equal 120, @tube.peek(:ready).ttr
      assert_equal 65536, @tube.peek(:ready).pri
      assert_equal 0, @tube.peek(:ready).delay
    end

    it "should insert a delayed job" do
      @tube.put "delayed put #{@time}", :delay => 1
      assert_equal "delayed put #{@time}", @tube.peek(:delayed).body
    end

    it "should support custom serializer" do
      Tuber.configure.job_serializer = lambda { |b| JSON.dump(b) }
      @tube.put({ foo: "bar"})
      assert_equal '{"foo":"bar"}', @tube.peek(:ready).body
    end

    after do
      Tuber::Connection.any_instance.unstub(:transmit)
      Tuber.configure.job_serializer = lambda { |b| b }
    end
  end # put

  describe "for #peek" do
    before do
      @time = Time.now.to_i
    end

    it "should peek delayed" do
      @tube.put "foo delay #{@time}", :delay => 1
      assert_equal "foo delay #{@time}", @tube.peek(:delayed).body
    end

    it "should peek ready" do
      @tube.put "foo ready #{@time}", :delay => 0
      assert_equal "foo ready #{@time}", @tube.peek(:ready).body
    end

    it "should peek buried" do
      @tube.put "foo buried #{@time}"
      @tube.reserve.bury

      assert_equal "foo buried #{@time}", @tube.peek(:buried).body
    end

    it "should return nil for empty peek" do
      assert_nil @tube.peek(:buried)
    end

    it "supports valid JSON" do
      json = '{ "foo" : "bar" }'
      @tube.put(json)
      assert_equal 'bar', JSON.parse(@tube.peek(:ready).body)['foo']
    end

    it "supports non valid JSON" do
      json = '{"message":"hi"}'
      @tube.put(json)
      assert_equal 'hi', JSON.parse(@tube.peek(:ready).body)['message']
    end

    it "supports passing crlf through" do
      @tube.put("\r\n")
      assert_equal "\r\n", @tube.peek(:ready).body
    end

    it "supports passing any byte value through" do
      bytes = (0..255).to_a.pack("c*")
      @tube.put(bytes)
      assert_equal bytes, @tube.peek(:ready).body
    end

    it "should support custom parser" do
      Tuber.configure.job_parser = lambda { |b| JSON.parse(b) }
      json = '{"message": "hi: there! this: is a long message"}'
      @tube.put(json)
      assert_equal 'hi: there! this: is a long message', @tube.peek(:ready).body['message']
    end

    after do
      Tuber.configure.job_parser = lambda { |b| b }
    end
  end # peek

  describe "for #reserve" do
    before do
      @time = Time.now.to_i
      @json = %Q&{ "foo" : "#{@time} bar" }&
      @tube.put @json
    end

    it "should reserve job" do
      @job = @tube.reserve
      assert_equal "#{@time} bar", JSON.parse(@job.body)['foo']
      @job.delete
    end

    it "should reserve job with block" do
      job = nil
      @tube.reserve { |j| job = j; job.delete }
      assert_equal "#{@time} bar", JSON.parse(job.body)['foo']
    end

    it "should support custom parser" do
      Tuber.configure.job_parser = lambda { |b| JSON.parse(b) }
      @job = @tube.reserve
      assert_equal "#{@time} bar", @job.body['foo']
      @job.delete
    end

    after do
      Tuber.configure.job_parser = lambda { |b| b }
    end
  end # reserve

  describe "for #put with tuber tags" do
    before do
      @beanstalk = stub
      @connection = stub(tube_used: 'baz')
      @beanstalk.stubs(:connection).returns(@connection)
      @tubes = stub
      @tubes.stubs(:use).with('baz').returns('baz')
      @beanstalk.stubs(:tubes).returns(@tubes)
      @tube = Tuber::Tube.new(@beanstalk, 'baz')
    end

    it "should append idp tag as string" do
      @connection.expects(:transmit).with("put 65536 0 120 4 idp:report\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", idp: "report"
    end

    it "should append idp tag with ttl as array" do
      @connection.expects(:transmit).with("put 65536 0 120 4 idp:report:300\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", idp: ["report", 300]
    end

    it "should append con tag as string" do
      @connection.expects(:transmit).with("put 65536 0 120 4 con:db\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", con: "db"
    end

    it "should append con tag with limit as array" do
      @connection.expects(:transmit).with("put 65536 0 120 4 con:db:3\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", con: ["db", 3]
    end

    it "should append grp tag" do
      @connection.expects(:transmit).with("put 65536 0 120 4 grp:batch-1\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", grp: "batch-1"
    end

    it "should append aft tag" do
      @connection.expects(:transmit).with("put 65536 0 120 4 aft:batch-0\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", aft: "batch-0"
    end

    it "should append all four tags" do
      @connection.expects(:transmit).with("put 65536 0 120 4 idp:key:60 con:db:2 grp:g1 aft:g0\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data", idp: ["key", 60], con: ["db", 2], grp: "g1", aft: "g0"
    end

    it "should send plain put without tags" do
      @connection.expects(:transmit).with("put 65536 0 120 4\r\ndata").returns({status: "INSERTED", id: "1"})
      @tube.put "data"
    end
  end # put with tuber tags

  describe "for #pause" do
    before do
      @time = Time.now.to_i
      @tube = Tuber::Tube.new(@beanstalk, 'bam')
      @tube.put "foo pause #{@time}"
    end

    it "should allow tube pause" do
      assert_equal 0, @tube.stats.pause
      @tube.pause(1)
      assert_equal 1, @tube.stats.pause
    end
  end # pause

  describe "for #stats" do
    before do
      @time = Time.now.to_i
      @tube.put "foo stats #{@time}"
      @stats = @tube.stats
    end

    it "should return total number of jobs in tube" do
      assert_equal 1, @stats['current_jobs_ready']
      assert_equal 0, @stats.current_jobs_delayed
    end

    it "should raise error for empty tube" do
      assert_raises(Tuber::NotFoundError) { @beanstalk.tubes.find('fake_tube').stats }
    end
  end # stats

  describe "for #kick" do
    before do
      @time, @time2 = 2.times.map { Time.now.to_i }
      @tube.put "kick #{@time}"
      @tube.put "kick #{@time2}"

      2.times.map { @tube.reserve.bury }
    end

    it "should kick 2 buried jobs" do
      assert_equal 2, @tube.stats.current_jobs_buried
      @tube.kick(2)
      assert_equal 0, @tube.stats.current_jobs_buried
      assert_equal 2, @tube.stats.current_jobs_ready
    end
  end # kick

  describe "for #clear" do
    @time = Time.now.to_i
    before do
      2.times { |i| @tube.put "to clear success #{i} #{@time}" }
      2.times { |i| @tube.put "to clear delayed #{i} #{@time}", :delay => 5 }
      2.times { |i| @tube.put "to clear bury #{i} #{@time}", :pri => 1 }
      @tube.reserve.bury while @tube.peek(:ready).stats['pri'] == 1
    end

    it "should clear all jobs in tube" do
      tube_counts = lambda { %w(ready buried delayed).map { |s| @tube.stats["current_jobs_#{s}"] } }
      assert_equal [2, 2, 2], tube_counts.call
      @tube.clear
      @tube.stats
      assert_equal [0, 0, 0], tube_counts.call
    end
  end # clear
  describe "for #flush" do
    before do
      require_tuber!
      @tube = Tuber::Tube.new(@beanstalk, 'flush_test')
      3.times { |i| @tube.put "flush job #{i}" }
    end

    it "should flush all jobs and return count" do
      count = @tube.flush
      assert_equal 3, count
      assert_nil @tube.peek(:ready)
    end

    it "should return 0 for empty tube" do
      @tube.flush
      count = @tube.flush
      assert_equal 0, count
    end
  end # flush

  describe "for #flush_buried" do
    before do
      require_tuber!
      @tube = Tuber::Tube.new(@beanstalk, 'flush_buried_test')
      @beanstalk.tubes.watch! 'flush_buried_test'
    end

    after do
      @tube.clear
    end

    it "should flush only buried jobs and return count" do
      2.times { |i| @tube.put "buried job #{i}" }
      2.times { @beanstalk.tubes.reserve.bury }
      @tube.put "ready job"

      count = @tube.flush_buried
      assert_equal 2, count
      assert_nil @tube.peek(:buried)
      refute_nil @tube.peek(:ready)
    end

    it "should return 0 when there are no buried jobs" do
      @tube.put "ready only"
      assert_equal 0, @tube.flush_buried
    end
  end # flush_buried
end # Tuber::Tube
