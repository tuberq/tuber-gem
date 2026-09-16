# frozen_string_literal: true

# test/connection_test.rb

require File.expand_path('../test_helper', __FILE__)

describe Tuber::Connection do

  describe 'for #new' do
    before do
      @host = 'localhost'
      @bc = Tuber::Connection.new(@host)
    end

    it "should store address, host and port" do
      assert_equal 'localhost', @bc.address
      assert_equal 'localhost', @bc.host
      assert_equal 11300, @bc.port
    end

    it "should init connection" do
      assert_kind_of TCPSocket, @bc.connection
      if @bc.connection.peeraddr[0] == 'AF_INET'
        assert_equal '127.0.0.1', @bc.connection.peeraddr[3]
      else
        assert_equal 'AF_INET6', @bc.connection.peeraddr[0]
        assert_equal '::1', @bc.connection.peeraddr[3]
      end
      assert_equal 11300, @bc.connection.peeraddr[1]
    end

    it "should raise on invalid connection" do
      assert_raises(Tuber::NotConnected) { Tuber::Connection.new("localhost:8544") }
    end

    it "should support array connection to single connection" do
      @bc2 = Tuber::Connection.new([@host])
      assert_equal 'localhost', @bc.address
      assert_equal 'localhost', @bc.host
      assert_equal 11300, @bc.port
    end

    it "should use TUBER_URL over BEANSTALKD_URL from env" do
      ENV['TUBER_URL'] = tuber_address.to_s
      ENV['BEANSTALKD_URL'] = 'unreachable.invalid:99999'
      bc = Tuber::Connection.new(nil)
      assert_equal tuber_address.to_s, bc.address
    ensure
      ENV.delete('TUBER_URL')
      ENV.delete('BEANSTALKD_URL')
    end

    it "should fall back to BEANSTALKD_URL from env" do
      ENV['BEANSTALKD_URL'] = tuber_address.to_s
      bc = Tuber::Connection.new(nil)
      assert_equal tuber_address.to_s, bc.address
    ensure
      ENV.delete('BEANSTALKD_URL')
    end
  end # new

  describe 'for timeout configuration' do
    after do
      Tuber.configure do |config|
        config.connect_timeout = nil
        config.resolv_timeout  = nil
        config.read_timeout    = nil
        config.write_timeout   = nil
      end
    end

    it "should pass connect_timeout and resolv_timeout to TCPSocket.new on Ruby >= 3.0" do
      skip("connect_timeout/resolv_timeout kwargs require Ruby >= 3.0") if RUBY_VERSION < "3.0"

      Tuber.configure do |config|
        config.connect_timeout = 2
        config.resolv_timeout  = 2
      end

      real_socket = TCPSocket.new('localhost', 11300)
      TCPSocket.expects(:new).with('localhost', 11300, connect_timeout: 2, resolv_timeout: 2).returns(real_socket)

      bc = Tuber::Connection.new('localhost')
      assert_kind_of TCPSocket, bc.connection
    end

    it "should ignore connect_timeout and resolv_timeout on Ruby < 3.0" do
      skip("connect_timeout/resolv_timeout kwargs are supported on Ruby >= 3.0") if RUBY_VERSION >= "3.0"

      Tuber.configure do |config|
        config.connect_timeout = 2
        config.resolv_timeout  = 4
      end

      real_socket = TCPSocket.new('localhost', 11300)
      TCPSocket.expects(:new).with('localhost', 11300).returns(real_socket)

      bc = Tuber::Connection.new('localhost')
      assert_same real_socket, bc.connection
    end

    it "should set SO_RCVTIMEO and SO_SNDTIMEO when read/write timeouts are configured" do
      Tuber.configure do |config|
        config.read_timeout  = 3
        config.write_timeout = 5
      end

      bc = Tuber::Connection.new('localhost')
      rcv = bc.connection.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO).unpack('l_l_')[0]
      snd = bc.connection.getsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO).unpack('l_l_')[0]
      assert_equal 3, rcv
      assert_equal 5, snd
    end

  end # timeout configuration

  describe 'for #transmit' do
    before do
      @host = 'localhost'
      @bc = Tuber::Connection.new(@host)
    end

    it "should return yaml loaded response" do
      res = @bc.transmit 'stats'
      refute_nil res[:body]['current-connections']
      assert_equal 'OK', res[:status]
    end

    it "should return id" do
      res = @bc.transmit "put 0 0 100 1\r\nX"
      assert res[:id]
      assert_equal 'INSERTED', res[:status]
    end

    it "should support dashes in response" do
      res = @bc.transmit "use foo-bar\r\n"
      assert_equal 'USING', res[:status]
      assert_equal 'foo-bar', res[:id]
    end

    it "should pass crlf through without changing its length" do
      res = @bc.transmit "put 0 0 100 2\r\n\r\n"
      assert_equal 'INSERTED', res[:status]
    end

    it "should handle *any* byte value without changing length" do
      res = @bc.transmit "put 0 0 100 256\r\n"+(0..255).to_a.pack("c*")
      assert_equal 'INSERTED', res[:status]
    end

    it "should retry idempotent command with success after one connection failure" do
      TCPSocket.any_instance.expects(:readline).times(2).
        raises(EOFError.new).then.
        returns("USING foo\n")

      res = @bc.transmit "use foo\r\n"
      assert_equal 'USING', res[:status]
    end

    it "should not retransmit delete after a connection failure" do
      TCPSocket.any_instance.expects(:readline).times(1).raises(EOFError.new)

      assert_raises(EOFError) { @bc.transmit "delete 56\r\n" }
    end

    it "should not retransmit put after a connection failure" do
      TCPSocket.any_instance.expects(:readline).times(1).raises(Errno::ECONNRESET.new)

      assert_raises(Errno::ECONNRESET) { @bc.transmit "put 0 0 100 4\r\ndata" }
    end

    it "heals the connection after a non-retransmitted failure" do
      $eof_once = false
      TCPSocket.prepend(Module.new do
        def readline
          if $eof_once == false
            $eof_once = true
            raise EOFError
          end
          super
        end
      end)

      assert_raises(EOFError) { @bc.transmit "delete 56\r\n" }

      # The reconnect still happened, so the next command works.
      res = @bc.transmit "use foo"
      assert_equal 'USING', res[:status]
    ensure
      $eof_once = true
    end

    it "should fail after exceeding retries with DrainingError" do
      TCPSocket.any_instance.expects(:readline).times(3).
        raises(Tuber::UnexpectedResponse.from_status("DRAINING", "delete 56"))

      assert_raises(Tuber::DrainingError) { @bc.transmit "delete 56\r\n" }
    end

    it "should fail after exceeding reconnect max retries" do
      # next connection attempts should fail
      TCPSocket.stubs(:new).times(3).raises(Errno::ECONNREFUSED.new)
      TCPSocket.any_instance.stubs(:readline).times(1).raises(EOFError.new)

      assert_raises(Tuber::NotConnected) { @bc.transmit "delete 56\r\n" }
    end

    it "tubes_watched are restored after reconnect" do
      client = Tuber.new('127.0.0.1:11300')
      client.tubes.watch! "another"

      $called = false
      TCPSocket.prepend Module.new {
        def readline
          if !$called
            $called = true
            raise EOFError
          end

          super
        end
      }

      assert_equal %w[another], client.tubes.watched.map(&:name)
    ensure
      # Leave the prepended module inert: with $called reset to nil it would
      # fire one more EOFError at an arbitrary later readline, which a
      # non-retransmitted command (delete/put) now surfaces as a failure.
      $called = true
    end

    it "replays tube weights and reserve mode after reconnect" do
      require_tuber!
      client = Tuber.new(tuber_address)
      client.tubes.watch("reconn_heavy", weight: 8)
      client.tubes.watch("reconn_light", weight: 1)
      client.tubes.ignore("default")
      client.tubes.reserve_mode(:weighted)

      $replayed = []
      $eof_pending = true
      TCPSocket.prepend Module.new {
        def write(data)
          $replayed << data.to_s if $replayed
          super
        end

        def readline
          if $eof_pending
            $eof_pending = false
            raise EOFError
          end

          super
        end
      }

      client.connection.transmit("list-tubes-watched")
      sent = $replayed

      assert_includes sent, "watch reconn_heavy 8\r\n"
      assert_includes sent, "watch reconn_light 1\r\n"
      assert_includes sent, "reserve-mode weighted\r\n"
      # Ordering matters: watch, then drop default, then set the mode.
      assert sent.index("watch reconn_heavy 8\r\n") < sent.index("ignore default\r\n"),
        "expected the watches to be replayed before 'ignore default'"
      assert sent.index("ignore default\r\n") < sent.index("reserve-mode weighted\r\n"),
        "expected 'reserve-mode' to be replayed after the tubes are watched"
    ensure
      # Leave the prepended module inert for the rest of the suite.
      $eof_pending = false
      $replayed = nil
      client.close if client
    end

    it "keeps watching default across a reconnect when default is watched" do
      client = Tuber.new(tuber_address)
      client.tubes.watch("reconn_extra")

      $replayed = []
      $eof_pending = true
      TCPSocket.prepend Module.new {
        def write(data)
          $replayed << data.to_s if $replayed
          super
        end

        def readline
          if $eof_pending
            $eof_pending = false
            raise EOFError
          end

          super
        end
      }

      client.connection.transmit("list-tubes-watched")
      sent = $replayed

      assert_includes sent, "watch reconn_extra\r\n"
      refute_includes sent, "ignore default\r\n"
      assert_equal %w[default reconn_extra].sort,
        client.tubes.watched.map(&:name).sort
    ensure
      $eof_pending = false
      $replayed = nil
      client.close if client
    end

    it "still reserves by weight after a reconnect" do
      require_tuber!
      consumer = Tuber.new(tuber_address)
      consumer.tubes.watch("reconn_heavy", weight: 8)
      consumer.tubes.watch("reconn_light", weight: 1)
      consumer.tubes.ignore("default")
      consumer.tubes.reserve_mode(:weighted)

      producer = Tuber.new(tuber_address)
      100.times do |i|
        producer.tubes["reconn_heavy"].put("h#{i}")
        producer.tubes["reconn_light"].put("l#{i}")
      end

      $eof_pending = true
      TCPSocket.prepend Module.new {
        def readline
          if $eof_pending
            $eof_pending = false
            raise EOFError
          end

          super
        end
      }

      counts = Hash.new(0)
      60.times do
        job = consumer.tubes.reserve(2)
        counts[job.body[0]] += 1
        job.delete
      end

      # 8:1 over interleaved puts is ~53/7; FIFO would be ~30/30.
      assert counts["h"] > 3 * counts["l"],
        "expected weighted reserve after reconnect, got heavy=#{counts["h"]} light=#{counts["l"]}"
    ensure
      $eof_pending = false
      if producer
        producer.connection.transmit("flush-tube reconn_heavy") rescue nil
        producer.connection.transmit("flush-tube reconn_light") rescue nil
        producer.close
      end
      consumer.close if consumer
    end
  end # transmit

  describe 'for idempotent insert response' do
    before do
      require_tuber!
      @host = tuber_address
      @bc = Tuber::Connection.new(@host)
      @idp_key = "testkey_#{Time.now.to_f}"
    end

    it "should return state for dedup hit" do
      @bc.transmit "use idp_test"
      res1 = @bc.transmit "put 0 0 100 4 idp:#{@idp_key}\r\ndata"
      assert_equal 'INSERTED', res1[:status]
      assert_nil res1[:state]

      res2 = @bc.transmit "put 0 0 100 4 idp:#{@idp_key}\r\ndata"
      assert_equal 'INSERTED', res2[:status]
      assert_equal res1[:id], res2[:id]
      assert_equal 'READY', res2[:state]
    end
  end # idempotent insert response

  describe 'for #reconnect!' do
    before do
      @host = tuber_address
      @bc = Tuber::Connection.new(@host)
    end

    after do
      @bc.close rescue nil
    end

    it "re-establishes a connection that was closed" do
      @bc.close
      assert_nil @bc.connection

      @bc.reconnect!

      assert_kind_of TCPSocket, @bc.connection
      assert_equal 'OK', @bc.transmit('stats')[:status]
    end

    it "replays watched tubes, weights and reserve mode" do
      require_tuber!
      client = Tuber.new(tuber_address)
      client.tubes.watch("reconn_bang_heavy", weight: 8)
      client.tubes.watch("reconn_bang_light", weight: 1)
      client.tubes.ignore("default")
      client.tubes.reserve_mode(:weighted)

      $replayed = []
      TCPSocket.prepend Module.new {
        def write(data)
          $replayed << data.to_s if $replayed
          super
        end
      }

      client.connection.reconnect!
      sent = $replayed

      assert_includes sent, "watch reconn_bang_heavy 8\r\n"
      assert_includes sent, "watch reconn_bang_light 1\r\n"
      assert_includes sent, "ignore default\r\n"
      assert_includes sent, "reserve-mode weighted\r\n"
      assert_equal %w[reconn_bang_heavy reconn_bang_light].sort,
        client.tubes.watched.map(&:name).sort
    ensure
      # Leave the prepended module inert for the rest of the suite.
      $replayed = nil
      client.close if client
    end

    it "retries while the server is still refusing connections" do
      # The outage shape: the socket is gone and the server will not accept
      # for another second or two. A single connect attempt loses that race.
      @bc.close
      real_socket = TCPSocket.new(tuber_address, 11300)
      TCPSocket.stubs(:new).
        raises(Errno::ECONNREFUSED.new).then.
        raises(Errno::ECONNREFUSED.new).then.
        returns(real_socket)

      @bc.reconnect!(retry_interval: 0.01)

      assert_same real_socket, @bc.connection
    end

    it "retries a connect that fails for a reason other than ECONNREFUSED" do
      # A remote host mid-restart answers EHOSTUNREACH or ETIMEDOUT as readily
      # as ECONNREFUSED; those must not escape as a raw Errno either.
      @bc.close
      real_socket = TCPSocket.new(tuber_address, 11300)
      TCPSocket.stubs(:new).
        raises(Errno::EHOSTUNREACH.new).then.
        returns(real_socket)

      @bc.reconnect!(retry_interval: 0.01)

      assert_same real_socket, @bc.connection
    end

    it "raises NotConnected naming the underlying error when the server stays down" do
      @bc.close
      TCPSocket.stubs(:new).raises(Errno::ECONNREFUSED.new)

      err = assert_raises(Tuber::NotConnected) { @bc.reconnect!(retry_interval: 0.01) }
      assert_match(/ECONNREFUSED/, err.message)
      assert_kind_of Errno::ECONNREFUSED, err.cause
    end

    it "is reachable from the Tuber instance" do
      client = Tuber.new(tuber_address)
      client.tubes.watch("reconn_delegate")

      client.reconnect!

      assert_includes client.tubes.watched.map(&:name), "reconn_delegate"
    ensure
      client.close if client
    end
  end # reconnect!

  describe 'for connect retries' do
    after do
      Tuber.configure do |config|
        config.connect_retries        = 0
        config.connect_retry_interval = Tuber::Connection::DEFAULT_RETRY_INTERVAL
      end
    end

    it "should make a single connect attempt by default" do
      TCPSocket.expects(:new).times(1).raises(Errno::ECONNREFUSED.new)

      assert_raises(Tuber::NotConnected) { Tuber::Connection.new('localhost') }
    end

    it "should retry the initial connect when connect_retries is configured" do
      real_socket = TCPSocket.new(tuber_address, 11300)
      Tuber.configure do |config|
        config.connect_retries        = 3
        config.connect_retry_interval = 0.01
      end

      TCPSocket.stubs(:new).
        raises(Errno::ECONNREFUSED.new).then.
        raises(Errno::ECONNREFUSED.new).then.
        returns(real_socket)

      bc = Tuber::Connection.new(tuber_address)

      assert_same real_socket, bc.connection
    end

    it "should give up after connect_retries and name the cause" do
      Tuber.configure do |config|
        config.connect_retries        = 2
        config.connect_retry_interval = 0.01
      end
      TCPSocket.expects(:new).times(3).raises(Errno::ECONNREFUSED.new)

      err = assert_raises(Tuber::NotConnected) { Tuber::Connection.new('localhost') }
      assert_match(/ECONNREFUSED/, err.message)
      assert_kind_of Errno::ECONNREFUSED, err.cause
    end

    it "should lift an established connection's reconnect budget too" do
      # One knob for "how long should a client ride out a server restart":
      # raising connect_retries has to cover the connection you already hold,
      # not only a cold start.
      bc = Tuber::Connection.new(tuber_address)
      real_socket = TCPSocket.new(tuber_address, 11300)

      Tuber.configure do |config|
        config.connect_retries        = 5
        config.connect_retry_interval = 0.01
      end

      # One dropped read, then four refused connects: past the built-in budget
      # of MAX_RETRIES, inside the configured one.
      $eof_pending = true
      TCPSocket.prepend Module.new {
        def readline
          if $eof_pending
            $eof_pending = false
            raise EOFError
          end

          super
        end
      }
      TCPSocket.stubs(:new).
        raises(Errno::ECONNREFUSED.new).then.
        raises(Errno::ECONNREFUSED.new).then.
        raises(Errno::ECONNREFUSED.new).then.
        raises(Errno::ECONNREFUSED.new).then.
        returns(real_socket)

      assert_equal 'OK', bc.transmit('stats')[:status]
      assert_same real_socket, bc.connection
    ensure
      $eof_pending = false
    end
  end # connect retries

  describe 'for NotConnected messages' do
    it "should keep the historical message as a prefix" do
      # Consumers match on this string. The cause is appended, never inserted.
      TCPSocket.stubs(:new).raises(Errno::ECONNREFUSED.new)

      err = assert_raises(Tuber::NotConnected) { Tuber::Connection.new('localhost:8544') }

      assert err.message.start_with?("Connection to beanstalk 'localhost:8544' is closed!"),
        "expected the historical message as a prefix, got #{err.message.inspect}"
    end

    it "should not blame an unrelated in-flight exception" do
      # Commands are very often issued from inside someone else's rescue block,
      # where $! is still set. The cause named has to be the one that stopped
      # this connect, not whatever the caller happened to be handling.
      bc = Tuber::Connection.new(tuber_address)
      bc.close

      err = begin
        raise ArgumentError, "something else entirely"
      rescue ArgumentError
        assert_raises(Tuber::NotConnected) { bc.transmit('stats') }
      end

      assert_equal "Connection to beanstalk '#{bc.host}:#{bc.port}' is closed!", err.message
    end
  end # NotConnected messages

  describe 'for #close' do
    before do
      @host = 'localhost'
      @bc = Tuber::Connection.new(@host)
    end

    it "should clear connection" do
      assert_kind_of TCPSocket, @bc.connection
      @bc.close
      assert_nil @bc.connection
      assert_raises(Tuber::NotConnected) { @bc.transmit 'stats' }
    end
  end # close
  describe 'for drain and undrain commands' do
    it "should return DRAINING status for drain command" do
      @bc = Tuber::Connection.new('localhost')
      TCPSocket.any_instance.stubs(:write)
      TCPSocket.any_instance.expects(:readline).returns("DRAINING\r\n")
      res = @bc.transmit("drain")
      assert_equal 'DRAINING', res[:status]
    end

    it "should return NOT_DRAINING status for undrain command" do
      @bc = Tuber::Connection.new('localhost')
      TCPSocket.any_instance.stubs(:write)
      TCPSocket.any_instance.expects(:readline).returns("NOT_DRAINING\r\n")
      res = @bc.transmit("undrain")
      assert_equal 'NOT_DRAINING', res[:status]
    end

    it "should still raise DrainingError for non-drain commands" do
      @bc = Tuber::Connection.new('localhost')
      TCPSocket.any_instance.stubs(:write)
      TCPSocket.any_instance.expects(:readline).times(3).returns("DRAINING\r\n")
      assert_raises(Tuber::DrainingError) { @bc.transmit("put 0 0 100 4\r\ntest") }
    end
  end # drain and undrain
end # Tuber::Connection
