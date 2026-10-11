# frozen_string_literal: true

require 'thread' unless defined?(Mutex)

%w(version configuration errors connection tube job stats schedules).each do |f|
  require "tuber/#{f}"
end

class Tuber

  # @!attribute connection
  #   @return <Tuber::Connection> returns the associated connection object
  attr_reader :connection

  # Initialize new instance of Tuber
  #
  # @param [String] address in the form "host:port"
  # @example
  #   Tuber.new('127.0.0.1:11300')
  #
  #   ENV['TUBER_URL'] = '127.0.0.1:11300'
  #   @b = Tuber.new
  #   @b.connection.host # => '127.0.0.1'
  #   @b.connection.port # => '11300'
  #
  def initialize(address=nil)
    @connection =  Connection.new(address)
  end

  # Returns Tuber::Tubes object for accessing tube related functions.
  #
  # @return [Tuber::Tubes] tubes object
  # @api public
  def tubes
    @tubes ||= Tuber::Tubes.new(self)
  end

  # Returns Tuber::Jobs object for accessing job related functions.
  #
  # @return [Tuber::Jobs] jobs object
  # @api public
  def jobs
    @jobs ||= Tuber::Jobs.new(self)
  end

  # Returns Tuber::Stats object for accessing beanstalk stats.
  #
  # @return [Tuber::Stats] stats object
  # @api public
  def stats
    @stats ||= Stats.new(self)
  end

  # Returns Tuber::Schedules object for the server's recurring schedules
  # (Tuber only).
  #
  # @return [Tuber::Schedules] schedules object
  # @api public
  def schedules
    @schedules ||= Schedules.new(self)
  end

  # Puts the server into drain mode, rejecting new puts.
  #
  # @return [Hash] Response from beanstalkd
  # @example
  #  @tuber_instance.drain
  #
  def drain
    connection.transmit("drain")
  end

  # Takes the server out of drain mode, allowing new puts.
  #
  # @return [Hash] Response from beanstalkd
  # @example
  #  @tuber_instance.undrain
  #
  def undrain
    connection.transmit("undrain")
  end

  # Re-establishes the connection and replays its tube state: watched tubes
  # with their weights, the used tube, and the reserve mode.
  #
  # Use this rather than building a new Tuber when a connection drops — a new
  # client starts with no tube state and, by default, gets a single connect
  # attempt, so it loses a race a reconnect would have won.
  #
  # @param [Integer, nil] tries Maximum number of connect attempts, nil for the
  #   configured default (see Tuber::Configuration#connect_retries)
  # @param [Numeric, nil] retry_interval Seconds between attempts, nil for the
  #   configured default
  # @return [Tuber] self
  # @raise [Tuber::NotConnected] Every connect attempt failed
  # @example
  #  @tuber_instance.reconnect!
  #
  def reconnect!(tries: nil, retry_interval: nil)
    connection.reconnect!(tries: tries, retry_interval: retry_interval)
    self
  end

  # Closes the related connection
  #
  # @example
  #  @tuber_instance.close
  #
  def close
    connection.close if connection
  end

  protected

  class << self
    # Yields a configuration block
    #
    # @example
    #   Tuber.configure do |config|
    #     config.job_parser = lamda { |body| Yaml.load(body)}
    #   end
    #
    def configure(&block)
      yield(configuration) if block_given?
      configuration
    end

    # Returns the configuration options set for Backburner
    #
    # @example
    #   Tuber.configuration.default_put_ttr => 120
    #
    def configuration
      @_configuration ||= Configuration.new
    end
  end
end # Tuber
