# frozen_string_literal: true

require 'yaml'
require 'socket'

class Russet
  # Represents a connection to a beanstalkd instance.
  class Connection

    # Default number of retries to send a command to a connection
    MAX_RETRIES = 3

    # Default retry interval
    DEFAULT_RETRY_INTERVAL = 1

    # @!attribute address
    #   @return [String] returns Beanstalkd server address
    #   @example
    #     @conn.address # => "localhost:11300"
    # @!attribute host
    #   @return [String] returns Beanstalkd server host
    #   @example
    #     @conn.host # => "localhost"
    # @!attribute port
    #  @return [Integer] returns Beanstalkd server port
    #  @example
    #    @conn.port # => "11300"
    # @!attribute connection
    #   @return [Net::TCPSocket] returns connection object
    attr_reader :address, :host, :port, :connection

    # @!attribute tubes_watched
    #   @returns [Array<String>] returns currently watched tube names
    # @!attribute tube_used
    #   @returns [String] returns currently used tube name
    attr_accessor :tubes_watched, :tube_used

    # Default port value for beanstalk connection
    DEFAULT_PORT = 11300

    # Commands that must not be retransmitted after a dropped connection.
    # The socket dying between write and readline leaves the first send's
    # fate unknown: a re-sent put can insert a duplicate job, and a re-sent
    # delete/release/bury/touch acts on a job whose reservation died with
    # the old socket — the server answers NOT_FOUND for work that actually
    # succeeded. For these verbs the connection is healed but the original
    # error is re-raised so the caller decides. Everything else (reserve,
    # watch, stats, peek, ...) converges to the same state on a re-send and
    # keeps the transparent retry.
    NON_IDEMPOTENT_COMMANDS = %w[put delete delete-batch release bury touch touch-all kick kick-job].freeze

    # Initializes new connection.
    #
    # @param [String] address beanstalkd instance address.
    # @example
    #   Russet::Connection.new('127.0.0.1')
    #   Russet::Connection.new('127.0.0.1:11300')
    #
    #   ENV['BEANSTALKD_URL'] = '127.0.0.1:11300'
    #   @b = Russet.new
    #   @b.connection.host # => '127.0.0.1'
    #   @b.connection.port # => '11300'
    #
    def initialize(address)
      @address = address || _host_from_env || Russet.configuration.beanstalkd_url
      @mutex = Mutex.new
      @tube_used = 'default'
      @tubes_watched = ['default']

      establish_connection
    rescue
      _raise_not_connected!
    end

    # Send commands to beanstalkd server via connection.
    #
    # @param [Hash{String => String, Number}>] options Retained for compatibility
    # @param [String] command Beanstalkd command
    # @return [Array<Hash{String => String, Number}>] Beanstalkd command response
    # @example
    #   @conn = Russet::Connection.new
    #   @conn.transmit('bury 123')
    #   @conn.transmit('stats')
    #
    def transmit(command, **options)
      verb = command.to_s[/\A\S+/]
      retransmit = !NON_IDEMPOTENT_COMMANDS.include?(verb)
      _with_retry(retransmit: retransmit, **options.slice(:retry_interval, :init)) do
        @mutex.synchronize do
          _raise_not_connected! unless connection

          command = command.dup.force_encoding('ASCII-8BIT') if command.respond_to?(:force_encoding)
          connection.write(command.to_s + "\r\n")
          res = connection.readline
          parse_response(command, res)
        end
      end
    end

    # Reserves a batch of jobs atomically.
    #
    # Without a +timeout+ (or with +timeout+ of 0) the command is non-blocking:
    # it returns whatever is ready immediately, possibly an empty array. With a
    # positive +timeout+ it long-polls, blocking until the first job arrives (up
    # to +timeout+ seconds) and then draining everything ready, up to +count+.
    #
    # @param [Integer] count Maximum number of jobs to reserve
    # @param [Integer] timeout Seconds to long-poll for the first job (nil = non-blocking)
    # @return [Array<Hash>] Array of job hashes with :status, :id, :body keys
    # @raise [Russet::DeadlineSoonError] A reserved job's TTR is about to expire
    #
    def reserve_batch(count, timeout = nil)
      _with_retry do
        @mutex.synchronize do
          _raise_not_connected! unless connection

          cmd = timeout ? "reserve-batch #{count} #{timeout}" : "reserve-batch #{count}"
          connection.write(cmd + "\r\n")

          header = connection.readline.chomp
          status, actual_count_str = header.split(/\s/, 2)

          raise UnexpectedResponse.from_status(status, cmd) unless status == "RESERVED_BATCH"

          actual_count = actual_count_str.to_i
          jobs = []
          actual_count.times do
            line = connection.readline.chomp
            _, job_id, bytes_str = line.split(/\s/)
            bytes = bytes_str.to_i
            body = connection.read(bytes)
            crlf = connection.read(2)
            raise ExpectedCrlfError.new("EXPECTED_CRLF", cmd) unless crlf == "\r\n"

            body = config.job_parser.call(body)
            jobs << { status: "RESERVED", id: job_id, body: body }
          end
          jobs
        end
      end
    end

    # Deletes a batch of jobs atomically.
    #
    # @param [Array<Integer, String>] ids Job IDs to delete
    # @return [Hash] with :deleted and :not_found counts
    #
    def delete_batch(ids)
      _with_retry(retransmit: false) do
        @mutex.synchronize do
          _raise_not_connected! unless connection

          cmd = "delete-batch #{ids.join(' ')}"
          connection.write(cmd + "\r\n")

          res = connection.readline.chomp
          status, deleted, not_found = res.split(/\s/)

          raise UnexpectedResponse.from_status(status, cmd) unless status == "DELETED_BATCH"

          { deleted: deleted.to_i, not_found: not_found.to_i }
        end
      end
    end

    # Close connection with beanstalkd server.
    #
    # @example
    #  @conn.close
    #
    def close
      if @connection
        @connection.close
        @connection = nil
      end
    end

    # Returns string representation of job.
    #
    # @example
    #  @conn.inspect
    #
    def to_s
      "#<Russet::Connection host=#{host.inspect} port=#{port.inspect}>"
    end
    alias :inspect :to_s

    def add_to_watched(tube_name)
      @tubes_watched << tube_name
      @tubes_watched.uniq
    end

    def remove_from_watched(tube_name)
      @tubes_watched.delete(tube_name)
    end

    protected

    # Establish a connection based on beanstalk address.
    #
    # @return [Net::TCPSocket] connection for specified address.
    # @raise [Russet::NotConnected] Could not connect to specified beanstalkd instance.
    # @example
    #  establish_connection('localhost:3005')
    #
    def establish_connection
      @address = address.first if address.is_a?(Array)
      match = address.split(':')
      @host, @port = match[0], Integer(match[1] || DEFAULT_PORT)

      tcp_opts = { connect_timeout: config.connect_timeout, resolv_timeout: config.resolv_timeout }.compact

      socket = if RUBY_VERSION >= "3.0" && tcp_opts.any?
        TCPSocket.new(@host, @port, **tcp_opts)
      else
        TCPSocket.new(@host, @port)
      end

      begin
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, _timeval_for(config.read_timeout)) if config.read_timeout
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, _timeval_for(config.write_timeout)) if config.write_timeout
        @connection = socket
      rescue
        socket.close rescue nil
        raise
      end
    end

    # Parses the response and returns the useful beanstalk response.
    # Will read the body if one is indicated by the status.
    #
    # @param [String] cmd Beanstalk command transmitted
    # @param [String] res Telnet command response
    # @return [Array<Hash{String => String, Number}>] Beanstalk response with `status`, `id`, `body`
    # @raise [Russet::UnexpectedResponse] Response from beanstalk command was an error status
    # @example
    #  parse_response("delete 56", "DELETED 56\nFOO")
    #   # => { :body => "FOO", :status => "DELETED", :id => 56 }
    #
    def parse_response(cmd, res)
      status = res.chomp
      body_values = status.split(/\s/)
      status = body_values[0]
      if status == "DRAINING" && cmd.strip.start_with?("drain")
        return { status: status }
      end
      raise UnexpectedResponse.from_status(status, cmd) if UnexpectedResponse::ERROR_STATES.include?(status)
      body = nil
      if status == 'FLUSHED'
        return { status: status, id: body_values[1] }
      end
      if ['OK','FOUND', 'RESERVED'].include?(status)
        bytes_size = body_values[-1].to_i
        raw_body = connection.read(bytes_size)
        body = if status == 'OK'
          psych_v4_valid_body = raw_body.gsub(/^(.*?): (.*)$/) { "#{$1}: #{$2.gsub(/[\:\-\~]/, '_')}" }
          YAML.load(psych_v4_valid_body)
        else
          config.job_parser.call(raw_body)
        end
        crlf = connection.read(2) # \r\n
        raise ExpectedCrlfError.new('EXPECTED_CRLF', cmd) if crlf != "\r\n"
      end
      id = body_values[1]
      response = { :status => status }
      response[:id] = id if id
      response[:body] = body if body
      response[:state] = body_values[2] if status == 'INSERTED' && body_values[2]
      response
    end

    # Returns configuration options for russet
    #
    # @return [Russet::Configuration] configuration object
    def config
      Russet.configuration
    end

    private

    def _initialize_tubes
      if @tubes_watched != ['default']
        tubes_watched.each do |t|
          transmit("watch #{t}", init: false)
        end

        transmit("ignore default", init: false)
      end

      transmit("use #{tube_used}", init: false) if @tube_used != 'default'
    end

    # Wrapper method for capturing certain failures and retry the payload block
    #
    # @param [Proc] block The command to execute.
    # @param [Integer] retry_interval The time to wait before the next retry
    # @param [Boolean] retransmit Whether the command is safe to re-send after
    #   a reconnect. When false the connection is still healed (reconnect +
    #   tube re-init) but the original connection error is re-raised.
    # @param [Integer] tries The maximum number of tries in draining mode
    # @return [Object] Result of the block passed
    #
    def _with_retry(retry_interval: DEFAULT_RETRY_INTERVAL, init: true, tries: MAX_RETRIES, retransmit: true, &block)
      yield
    rescue EOFError, Errno::ECONNRESET, Errno::EPIPE,
      Errno::ECONNREFUSED => ex
      _reconnect(ex, retry_interval)
      _initialize_tubes if init
      raise ex unless retransmit
      retry
    rescue Russet::DrainingError
      tries -= 1
      if tries.zero?
        close
        raise
      end
      sleep(retry_interval)
      retry
    end

    # Tries to re-establish connection to the beanstalkd
    #
    # @param [Exception] original_exception The exception caused the retry
    # @param [Integer] retry_interval The time to wait before the next reconnect
    # @param [Integer] tries The maximum number of attempts to reconnect
    def _reconnect(original_exception, retry_interval, tries=MAX_RETRIES)
      close
      establish_connection
    rescue Errno::ECONNREFUSED
      tries -= 1
      if tries.zero?
        _raise_not_connected!
      end
      sleep(retry_interval || DEFAULT_RETRY_INTERVAL)
      retry
    end

    # The host provided by BEANSTALKD_URL environment variable, if available.
    #
    # @return [String] A beanstalkd host address
    # @example
    #  ENV['BEANSTALKD_URL'] = "localhost:1212"
    #   # => 'localhost:1212'
    #
    def _host_from_env
      ENV['BEANSTALKD_URL'].respond_to?(:length) && ENV['BEANSTALKD_URL'].length > 0 && ENV['BEANSTALKD_URL'].strip
    end

    # Packs a timeout value (in seconds) into a struct timeval binary string.
    # Supports fractional seconds (e.g., 0.5 => 500000 usec).
    def _timeval_for(timeout)
      sec = timeout.to_i
      usec = ((timeout.to_f - sec) * 1_000_000).to_i
      [sec, usec].pack('l_l_')
    end

    # Raises an error to be triggered when the connection has failed
    # @raise [Russet::NotConnected] Beanstalkd is no longer connected
    def _raise_not_connected!
      raise Russet::NotConnected, "Connection to beanstalk '#{@host}:#{@port}' is closed!"
    end

  end # Connection
end # Russet
