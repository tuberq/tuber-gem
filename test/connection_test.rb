# frozen_string_literal: true

# test/connection_test.rb

require File.expand_path('../test_helper', __FILE__)

describe Beaneater::Connection do

  describe 'for #new' do
    before do
      @host = 'localhost'
      @bc = Beaneater::Connection.new(@host)
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
      assert_raises(Beaneater::NotConnected) { Beaneater::Connection.new("localhost:8544") }
    end

    it "should support array connection to single connection" do
      @bc2 = Beaneater::Connection.new([@host])
      assert_equal 'localhost', @bc.address
      assert_equal 'localhost', @bc.host
      assert_equal 11300, @bc.port
    end
  end # new

  describe 'for timeout configuration' do
    after do
      Beaneater.configure do |config|
        config.connect_timeout = nil
        config.resolv_timeout  = nil
        config.read_timeout    = nil
        config.write_timeout   = nil
      end
    end

    it "should pass connect_timeout and resolv_timeout to TCPSocket.new on Ruby >= 3.0" do
      skip("connect_timeout/resolv_timeout kwargs require Ruby >= 3.0") if RUBY_VERSION < "3.0"

      Beaneater.configure do |config|
        config.connect_timeout = 2
        config.resolv_timeout  = 2
      end

      real_socket = TCPSocket.new('localhost', 11300)
      TCPSocket.expects(:new).with('localhost', 11300, connect_timeout: 2, resolv_timeout: 2).returns(real_socket)

      bc = Beaneater::Connection.new('localhost')
      assert_kind_of TCPSocket, bc.connection
    end

    it "should ignore connect_timeout and resolv_timeout on Ruby < 3.0" do
      skip("connect_timeout/resolv_timeout kwargs are supported on Ruby >= 3.0") if RUBY_VERSION >= "3.0"

      Beaneater.configure do |config|
        config.connect_timeout = 2
        config.resolv_timeout  = 4
      end

      real_socket = TCPSocket.new('localhost', 11300)
      TCPSocket.expects(:new).with('localhost', 11300).returns(real_socket)

      bc = Beaneater::Connection.new('localhost')
      assert_same real_socket, bc.connection
    end

    it "should set SO_RCVTIMEO and SO_SNDTIMEO when read/write timeouts are configured" do
      Beaneater.configure do |config|
        config.read_timeout  = 3
        config.write_timeout = 5
      end

      bc = Beaneater::Connection.new('localhost')
      rcv = bc.connection.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO).unpack('l_l_')[0]
      snd = bc.connection.getsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO).unpack('l_l_')[0]
      assert_equal 3, rcv
      assert_equal 5, snd
    end

  end # timeout configuration

  describe 'for #transmit' do
    before do
      @host = 'localhost'
      @bc = Beaneater::Connection.new(@host)
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
        raises(Beaneater::UnexpectedResponse.from_status("DRAINING", "delete 56"))

      assert_raises(Beaneater::DrainingError) { @bc.transmit "delete 56\r\n" }
    end

    it "should fail after exceeding reconnect max retries" do
      # next connection attempts should fail
      TCPSocket.stubs(:new).times(3).raises(Errno::ECONNREFUSED.new)
      TCPSocket.any_instance.stubs(:readline).times(1).raises(EOFError.new)

      assert_raises(Beaneater::NotConnected) { @bc.transmit "delete 56\r\n" }
    end

    it "tubes_watched are restored after reconnect" do
      client = Beaneater.new('127.0.0.1:11300')
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
  end # transmit

  describe 'for idempotent insert response' do
    before do
      @host = 'localhost'
      @bc = Beaneater::Connection.new(@host)
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

  describe 'for #close' do
    before do
      @host = 'localhost'
      @bc = Beaneater::Connection.new(@host)
    end

    it "should clear connection" do
      assert_kind_of TCPSocket, @bc.connection
      @bc.close
      assert_nil @bc.connection
      assert_raises(Beaneater::NotConnected) { @bc.transmit 'stats' }
    end
  end # close
  describe 'for drain and undrain commands' do
    it "should return DRAINING status for drain command" do
      @bc = Beaneater::Connection.new('localhost')
      TCPSocket.any_instance.stubs(:write)
      TCPSocket.any_instance.expects(:readline).returns("DRAINING\r\n")
      res = @bc.transmit("drain")
      assert_equal 'DRAINING', res[:status]
    end

    it "should return NOT_DRAINING status for undrain command" do
      @bc = Beaneater::Connection.new('localhost')
      TCPSocket.any_instance.stubs(:write)
      TCPSocket.any_instance.expects(:readline).returns("NOT_DRAINING\r\n")
      res = @bc.transmit("undrain")
      assert_equal 'NOT_DRAINING', res[:status]
    end

    it "should still raise DrainingError for non-drain commands" do
      @bc = Beaneater::Connection.new('localhost')
      TCPSocket.any_instance.stubs(:write)
      TCPSocket.any_instance.expects(:readline).times(3).returns("DRAINING\r\n")
      assert_raises(Beaneater::DrainingError) { @bc.transmit("put 0 0 100 4\r\ntest") }
    end
  end # drain and undrain
end # Beaneater::Connection
