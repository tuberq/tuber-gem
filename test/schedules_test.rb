# frozen_string_literal: true

# test/schedules_test.rb

require File.expand_path('../test_helper', __FILE__)

describe Tuber::Schedules do
  before do
    @beanstalk = Tuber.new(tuber_address)
    @schedules = @beanstalk.schedules
    # Owners are namespaces, so a unique one keeps tests apart.
    @owner = "gemtest.#{Process.pid}.#{rand(1 << 30)}"
  end

  after do
    begin
      @schedules.sync(@owner, allow_empty: true) if $tuber_schedules
    rescue Tuber::UnexpectedResponse, Tuber::NotConnected
      # the test already failed; don't bury its error under this one
    end
  end

  def add_two(sync)
    sync.add "rollup", tube: "gemtest.sched", cron: "5 * * * *", body: "rollup"
    sync.add "checkin", tube: "gemtest.sched", every: 60, body: "checkin"
  end

  describe "for #sync" do
    before { require_schedules! }

    it "adds, keeps, changes and removes entries" do
      assert_equal [2, 0, 0, 0], @schedules.sync(@owner) { |s| add_two(s) }.to_a
      assert_equal [0, 0, 0, 2], @schedules.sync(@owner) { |s| add_two(s) }.to_a
      assert_equal [[@owner, "checkin"], [@owner, "rollup"]], @schedules.list(@owner).sort
      assert_includes @schedules.list, [@owner, "rollup"]

      result = @schedules.sync(@owner) do |s|
        s.add "rollup", tube: "gemtest.sched", cron: "15 * * * *", body: "rollup"
      end
      assert_equal [0, 1, 1, 0], result.to_a
      assert_equal [[@owner, "rollup"]], @schedules.list(@owner)
    end

    it "lands each option in the entry tuber stores" do
      @schedules.sync(@owner) do |s|
        s.add "nightly", tube: "gemtest.sched", cron: "0 2 * * *", zone: "Australia/Melbourne",
              body: "nightly", idp: ["nightly", 300], con: ["maintenance", 2], catchup: 300,
              pri: 1024, delay: 5, ttr: 60
        s.add "hourly", tube: "gemtest.sched", every: "1h", offset: "5m", body: "hourly", catchup: false
        s.add "daily", tube: "gemtest.sched", spec: "@daily", body: "daily"
      end

      nightly = @schedules.stats(@owner, "nightly")
      assert_equal "0 2 * * * Australia/Melbourne", nightly.spec
      assert_equal "gemtest.sched", nightly.tube
      assert_equal [1024, 5, 60], [nightly.pri, nightly.delay, nightly.ttr]
      assert_equal "idp:nightly:300 con:maintenance:2", nightly.tags
      assert_equal "once within 300s", nightly.catchup

      hourly = @schedules.stats(@owner, "hourly")
      assert_equal "every 1h offset 5m", hourly.spec
      assert_equal "never", hourly.catchup
      assert_nil hourly.tags

      daily = @schedules.stats(@owner, "daily")
      assert_equal "once", daily.catchup
      config = Tuber.configuration
      assert_equal [config.default_put_pri, config.default_put_delay, config.default_put_ttr],
                   [daily.pri, daily.delay, daily.ttr]
    end

    it "raises naming the refused entry, and leaves the previous set in place" do
      nightly = lambda do |s|
        s.add "nightly", tube: "gemtest.sched", cron: "0 2 * * *", zone: "Australia/Melbourne", body: "n"
      end
      @schedules.sync(@owner, &nightly)

      err = assert_raises(Tuber::ScheduleSyncError) do
        @schedules.sync(@owner) do |s|
          s.add "nightly", tube: "gemtest.sched", cron: "0 3 * * *", zone: "Australia/Melbourne", body: "n"
          s.add "typo", tube: "gemtest.sched", cron: "0 2 * * *", zone: "Australia/Melborne", body: "t"
        end
      end
      assert_equal "BAD_SCHEDULE", err.status
      assert_equal "typo", err.entry
      assert_equal @owner, err.owner
      refute err.applied?
      assert_match %r{Australia/Melborne}, err.message

      assert_equal [[@owner, "nightly"]], @schedules.list(@owner)
      assert_equal "0 2 * * * Australia/Melbourne", @schedules.stats(@owner, "nightly").spec
      # The connection left sync mode: the next sync goes through.
      assert_equal [0, 0, 0, 1], @schedules.sync(@owner, &nightly).to_a
    end

    it "refuses an empty set unless allow_empty" do
      @schedules.sync(@owner) { |s| add_two(s) }

      assert_raises(ArgumentError) { @schedules.sync(@owner) { |_s| } }
      assert_raises(ArgumentError) { @schedules.sync(@owner) }
      assert_equal 2, @schedules.list(@owner).size

      assert_equal [0, 0, 2, 0], @schedules.sync(@owner, allow_empty: true).to_a
      assert_equal [], @schedules.list(@owner)
    end

    it "sends nothing when an entry is invalid" do
      @schedules.sync(@owner) { |s| add_two(s) }

      assert_raises(ArgumentError) do
        @schedules.sync(@owner) do |s|
          s.add "rollup", tube: "gemtest.sched", cron: "5 * * * *", body: "rollup"
          s.add "broken", tube: "gemtest.sched", cron: "5 * * * *", every: 60, body: "broken"
        end
      end
      assert_equal 2, @schedules.list(@owner).size
    end

    it "puts the body into the tube when an entry fires" do
      serializer, parser = Tuber.configuration.job_serializer, Tuber.configuration.job_parser
      Tuber.configure do |config|
        config.job_serializer = lambda { |body| JSON.dump(body) }
        config.job_parser = lambda { |body| JSON.parse(body) }
      end
      tube = "gemtest.fire.#{rand(1 << 30)}"
      @schedules.sync(@owner) do |s|
        s.add "tick", tube: tube, every: 1, body: { "class" => "TickJob", "args" => [1] }
      end

      job = @beanstalk.tubes.find(tube).reserve(3)
      assert_equal({ "class" => "TickJob", "args" => [1] }, job.body)
      job.delete
    ensure
      Tuber.configure do |config|
        config.job_serializer = serializer
        config.job_parser = parser
      end
    end

    it "re-runs the whole sync when the connection drops partway" do
      $sync_writes = []
      $drop_mid_sync = true
      TCPSocket.prepend Module.new {
        def write(data)
          $sync_writes << data.to_s if $sync_writes
          super
        end

        def readline
          if $drop_mid_sync && $sync_writes.last.to_s.start_with?("schedule-put")
            $drop_mid_sync = false
            close # the server sees the connection go and discards what was staged
            raise EOFError
          end
          super
        end
      }

      result = @schedules.sync(@owner) { |s| add_two(s) }

      assert_equal 2, $sync_writes.count { |w| w.start_with?("schedule-begin") }
      assert_equal [2, 0, 0, 0], result.to_a
      assert_equal [[@owner, "checkin"], [@owner, "rollup"]], @schedules.list(@owner).sort
    ensure
      # Leave the prepended module inert for the rest of the suite.
      $drop_mid_sync = false
      $sync_writes = nil
    end

    it "isn't held up by a blocking reserve on the client's connection" do
      tube = "gemtest.empty.#{rand(1 << 30)}"
      reserver = Thread.new do
        @beanstalk.tubes.find(tube).reserve(3)
      rescue Tuber::TimedOutError
        nil
      end
      sleep 0.3 # let the reserve take the connection

      started = Time.now
      @schedules.sync(@owner) { |s| add_two(s) }
      assert_operator Time.now - started, :<, 1.5, "the sync waited for the reserve to time out"
    ensure
      reserver.join if reserver
    end

    it "closes the connection it syncs on, refused or not" do
      # A leaked socket closes only when it is garbage collected, which would
      # hide the leak; and earlier tests' unclosed clients must go first.
      GC.start
      GC.disable
      sleep 0.2 # let the server notice anything just closed
      before = @beanstalk.stats["current-connections"]

      @schedules.sync(@owner) { |s| add_two(s) }
      assert_raises(Tuber::ScheduleSyncError) do
        @schedules.sync(@owner) do |s|
          s.add "typo", tube: "gemtest.sched", cron: "0 2 * * *", zone: "Australia/Melborne", body: "t"
        end
      end

      after = nil
      10.times do # the server notices a close a moment later
        after = @beanstalk.stats["current-connections"]
        break if after <= before
        sleep 0.1
      end
      assert_operator after, :<=, before
    ensure
      GC.enable
    end

    it "leaves nothing behind when an unexpected error interrupts it" do
      $fail_mid_sync = true
      $sync_last_write = nil
      TCPSocket.prepend Module.new {
        def write(data)
          $sync_last_write = data.to_s if $fail_mid_sync
          super
        end

        def readline
          if $fail_mid_sync && $sync_last_write.to_s.start_with?("schedule-put")
            $fail_mid_sync = false
            raise IOError, "simulated read failure" # e.g. a read timeout: not a dropped socket
          end
          super
        end
      }

      assert_raises(IOError) { @schedules.sync(@owner) { |s| add_two(s) } }

      # The client's connection still answers its own commands in step...
      assert_equal "default", @beanstalk.connection.transmit("list-tube-used")[:id]
      # ...nothing of the interrupted sync was committed, and the next sync starts clean.
      assert_equal [], @schedules.list(@owner)
      assert_equal [2, 0, 0, 0], @schedules.sync(@owner) { |s| add_two(s) }.to_a
    ensure
      $fail_mid_sync = false
    end
  end # sync

  describe "for #stats" do
    before { require_schedules! }

    it "returns times as Time in the entry's zone, and counters as Integers" do
      @schedules.sync(@owner) do |s|
        s.add "nightly", tube: "gemtest.sched", cron: "0 2 * * *", zone: "Australia/Melbourne", body: "n"
      end

      stats = @schedules.stats(@owner, "nightly")
      assert_equal @owner, stats.owner
      assert_kind_of Time, stats.synced_at
      assert_kind_of Time, stats.next_fire
      assert_includes [10 * 3600, 11 * 3600], stats.next_fire.utc_offset
      assert_includes [2, 3], stats.next_fire.hour # 3 on a spring-forward day
      assert stats.next_fire < stats.next_fire_2
      assert stats.next_fire_2 < stats.next_fire_3
      assert_equal stats.next_fire_2, stats["next-fire-2"]
      assert_nil stats.last_fire
      assert_nil stats.last_result
      assert_equal 0, stats.total_fires
      assert_equal 0, stats.total_deduped_buried
      assert_equal 0, stats.buried_streak
    end

    it "returns nil for an entry it doesn't hold" do
      assert_nil @schedules.stats(@owner, "nope")
    end

    it "keeps a name and tube made of digits as Strings" do
      @schedules.sync(@owner) { |s| s.add "2026", tube: "123", every: 60, body: "b" }
      stats = @schedules.stats(@owner, "2026")
      assert_equal "2026", stats.name
      assert_equal "123", stats.tube
    end
  end # stats
end # Tuber::Schedules

# Replies a healthy server won't produce on demand. No @beanstalk here, so the
# suite's teardown doesn't talk through the stubbed socket.
describe "Tuber::Schedules sync refusals" do
  before do
    @client = Tuber.new(tuber_address)
    @owner = "gemtest.stubbed"
    TCPSocket.any_instance.stubs(:write)
  end

  after do
    @client.close
  end

  def sync_one
    @client.schedules.sync(@owner) { |s| s.add "a", tube: "gemtest.sched", every: 60, body: "a" }
  end

  it "says the set is live when the commit couldn't be written" do
    TCPSocket.any_instance.stubs(:readline).returns("SYNCING #{@owner}\r\n", "STAGED\r\n", "INTERNAL_ERROR\r\n")
    err = assert_raises(Tuber::ScheduleSyncError) { sync_one }
    assert_equal "INTERNAL_ERROR", err.status
    assert_nil err.entry
    assert err.applied?
    assert_match(/is live/, err.message)
  end

  it "says nothing changed when the commit is refused" do
    TCPSocket.any_instance.stubs(:readline).returns("SYNCING #{@owner}\r\n", "STAGED\r\n", "OUT_OF_STORAGE\r\n")
    err = assert_raises(Tuber::ScheduleSyncError) { sync_one }
    assert_equal "OUT_OF_STORAGE", err.status
    refute err.applied?
    assert_match(/Nothing changed/, err.message)
  end

  it "aborts the sync before raising for a refused entry" do
    TCPSocket.any_instance.expects(:write).with("schedule-abort\r\n")
    TCPSocket.any_instance.stubs(:readline).returns("SYNCING #{@owner}\r\n", "JOB_TOO_BIG\r\n", "ABORTED\r\n")
    err = assert_raises(Tuber::ScheduleSyncError) { sync_one }
    assert_equal "JOB_TOO_BIG", err.status
    assert_equal "a", err.entry
  end

  it "explains a server without schedules" do
    TCPSocket.any_instance.stubs(:readline).returns("UNKNOWN_COMMAND\r\n")
    err = assert_raises(Tuber::ScheduleSyncError) { sync_one }
    assert_equal "UNKNOWN_COMMAND", err.status
    assert_match(/no recurring schedules/, err.message)
  end
end

describe Tuber::Schedules::Builder do
  before do
    @builder = Tuber::Schedules::Builder.new
  end

  it "writes the schedule-put arguments: tags before the spec" do
    @builder.add "nightly", tube: "splat.maintenance", cron: "0 2 * * *", zone: "Australia/Melbourne",
                 body: "{}", idp: ["nightly", 300], con: "maintenance", catchup: 300, pri: 1024
    entry = @builder.entries.first
    assert_equal "nightly", entry.name
    assert_equal "nightly splat.maintenance 1024 0 120 2 idp:nightly:300 con:maintenance catchup:300 " \
                 "0 2 * * * Australia/Melbourne", entry.line
    assert_equal Encoding::BINARY, entry.body.encoding
  end

  it "counts the body in bytes" do
    @builder.add "utf8", tube: "t", every: 60, body: "café"
    assert_equal "utf8 t 65536 0 120 5 every 60s", @builder.entries.first.line
  end

  it "writes every: and offset:, and catchup: :never" do
    @builder.add :hourly, tube: "t", every: 3600, offset: 300, body: "b", catchup: :never
    assert_equal "hourly t 65536 0 120 1 catchup:0 every 3600s offset 300s", @builder.entries.first.line
  end

  it "refuses an entry tuber would refuse, or that would break the line" do
    bad = [
      { tube: "t", body: "b" },                                     # no spec
      { tube: "t", body: "b", cron: "5 * * * *", every: 60 },       # two specs
      { tube: "t", body: "b", every: 60, zone: "UTC" },             # zone without cron
      { tube: "t", body: "b", cron: "5 * * * *", offset: "5m" },    # offset without every
      { tube: "t", body: "b", spec: "5 * * * * UTC+10:00" },        # a colon reads as a tag
      { tube: "t", body: "b", spec: "5 * * * *\r\nflush-tube t" },  # a second command
      { tube: "-t", body: "b", every: 60 },                         # bad tube name
      { tube: "t", body: { "a" => 1 }, every: 60 },                 # body isn't a String
      { tube: "t", body: "b", every: 60, idp: "two words" },        # tag with a space
      { tube: "t", body: "b", every: 60, con: "" },                 # empty tag key
      { tube: "t", body: "b", every: 60, catchup: -1 },
      { tube: "t", body: "b", every: 60, catchup: "soon" },
    ]
    bad.each do |options|
      assert_raises(ArgumentError, options.inspect) { Tuber::Schedules::Builder.new.add("name", **options) }
    end

    ["", "-name", "has space", "x" * 201, nil].each do |name|
      assert_raises(ArgumentError, name.inspect) { @builder.add(name, tube: "t", every: 60, body: "b") }
    end
  end

  it "refuses a name added twice" do
    @builder.add "once", tube: "t", every: 60, body: "b"
    assert_raises(ArgumentError) { @builder.add "once", tube: "t", every: 120, body: "b" }
  end
end
