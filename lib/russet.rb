# frozen_string_literal: true

require 'thread' unless defined?(Mutex)

%w(version configuration errors connection tube job stats).each do |f|
  require "russet/#{f}"
end

class Russet

  # @!attribute connection
  #   @return <Russet::Connection> returns the associated connection object
  attr_reader :connection

  # Initialize new instance of Russet
  #
  # @param [String] address in the form "host:port"
  # @example
  #   Russet.new('127.0.0.1:11300')
  #
  #   ENV['BEANSTALKD_URL'] = '127.0.0.1:11300'
  #   @b = Russet.new
  #   @b.connection.host # => '127.0.0.1'
  #   @b.connection.port # => '11300'
  #
  def initialize(address=nil)
    @connection =  Connection.new(address)
  end

  # Returns Russet::Tubes object for accessing tube related functions.
  #
  # @return [Russet::Tubes] tubes object
  # @api public
  def tubes
    @tubes ||= Russet::Tubes.new(self)
  end

  # Returns Russet::Jobs object for accessing job related functions.
  #
  # @return [Russet::Jobs] jobs object
  # @api public
  def jobs
    @jobs ||= Russet::Jobs.new(self)
  end

  # Returns Russet::Stats object for accessing beanstalk stats.
  #
  # @return [Russet::Stats] stats object
  # @api public
  def stats
    @stats ||= Stats.new(self)
  end

  # Puts the server into drain mode, rejecting new puts.
  #
  # @return [Hash] Response from beanstalkd
  # @example
  #  @russet_instance.drain
  #
  def drain
    connection.transmit("drain")
  end

  # Takes the server out of drain mode, allowing new puts.
  #
  # @return [Hash] Response from beanstalkd
  # @example
  #  @russet_instance.undrain
  #
  def undrain
    connection.transmit("undrain")
  end

  # Closes the related connection
  #
  # @example
  #  @russet_instance.close
  #
  def close
    connection.close if connection
  end

  protected

  class << self
    # Yields a configuration block
    #
    # @example
    #   Russet.configure do |config|
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
    #   Russet.configuration.default_put_ttr => 120
    #
    def configuration
      @_configuration ||= Configuration.new
    end
  end
end # Russet
