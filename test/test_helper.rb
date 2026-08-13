# frozen_string_literal: true

ENV["TEST"] = 'true'
require 'rubygems'
require 'coveralls'
Coveralls.wear!
require 'minitest/autorun'
$:.unshift File.expand_path("../../lib")
require 'tuber'
require 'timeout'
begin
  require 'mocha/minitest'
rescue LoadError
  require 'mocha'
end
require 'json'

class MiniTest::Unit::TestCase

  # Address of the server the integration-style tests talk to. Override with
  # TUBER_TEST_ADDRESS when localhost:11300 isn't the server you mean
  # (e.g. TUBER_TEST_ADDRESS=127.0.0.1 when another queue holds the IPv6 port).
  def tuber_address
    ENV.fetch('TUBER_TEST_ADDRESS', 'localhost')
  end

  # True when the server under test is Tuber rather than stock beanstalkd.
  def tuber_server?
    if $tuber_server.nil?
      client = Tuber.new(tuber_address)
      begin
        $tuber_server = client.connection.transmit('stats')[:body]['version'].to_s.include?('tuber')
      ensure
        client.close
      end
    end
    $tuber_server
  end

  # Skips the current test unless the server speaks Tuber's extended protocol
  # (reserve-batch, touch-all, flush-buried, ...).
  def require_tuber!
    skip "requires a Tuber server, not stock beanstalkd" unless tuber_server?
  end

  # Cleans up all jobs from specific tubes
  #
  # @example
  #   cleanup_tubes!(['foo'], @beanstalk)
  #
  def cleanup_tubes!(tubes, client=nil)
    client ||= @beanstalk
    tubes.each do |name|
      client.tubes.find(name).clear
    end
  end

  # Cleans up all jobs from all tubes known to the connection
  def flush_all(client=nil)
    client ||= @beanstalk

    # Do not continue if it is a mock or the connection has been closed
    return if !client.is_a?(Tuber) || !client.connection.connection

    client.tubes.all.each do |tube|
      tube.clear
    end
  end

  # Run clean up after each test to ensure clean state in all tests
  def teardown
    flush_all
  end
end
