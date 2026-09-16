# frozen_string_literal: true

require 'yaml'
require 'socket'

class Tuber
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
    # @!attribute reserve_mode
    #   @returns [String, Symbol, nil] the reserve mode set on this connection,
    #     nil when it was never set (the server default is fifo)
    attr_accessor :tube_used, :reserve_mode
    attr_reader :tubes_watched

    # @!attribute tube_weights
    #   @returns [Hash{String => Integer}] weight last watched with, per tube.
    #     Tubes watched without a weight are absent: the server resets a tube's
    #     weight to 1 on a plain `watch`, so "no weight" is state worth keeping.
    attr_reader :tube_weights

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

    # Errno names that mean "the server is not reachable right now" during a
    # connect attempt. Every one of them is worth another try: a host coming
    # back from a restart answers EHOSTUNREACH or ETIMEDOUT as readily as
    # ECONNREFUSED, and a raw Errno escaping the connection is a class no
    # consumer thinks to rescue.
    CONNECT_ERROR_NAMES = %w[
      ECONNREFUSED ECONNRESET ECONNABORTED ETIMEDOUT
      EHOSTUNREACH EHOSTDOWN ENETUNREACH ENETDOWN EPIPE
    ].freeze

    # The resolved exception classes, skipping any Errno the platform lacks.
    # SocketError covers a name that will not resolve (a DNS server restarting
    # alongside the queue), IO::TimeoutError a connect_timeout on Ruby >= 3.2.
    CONNECT_ERRORS = (
      CONNECT_ERROR_NAMES.map { |name| Errno.const_get(name) if Errno.const_defined?(name) }.compact +
      [SocketError] +
      (defined?(IO::TimeoutError) ? [IO::TimeoutError] : [])
    ).freeze

    # Initializes new connection.
    #
    # @param [String] address beanstalkd instance address.
    # @example
    #   Tuber::Connection.new('127.0.0.1')
    #   Tuber::Connection.new('127.0.0.1:11300')
    #
    #   ENV['TUBER_URL'] = '127.0.0.1:11300'
    #   @b = Tuber.new
    #   @b.connection.host # => '127.0.0.1'
    #   @b.connection.port # => '11300'
    #
    # @raise [Tuber::NotConnected] Could not connect. The underlying error is
    #   named in the message and kept as the exception's +cause+.
    #
    def initialize(address)
      @address = address || _host_from_env || Tuber.configuration.tuber_url
      @mutex = Mutex.new
      @tube_used = 'default'
      @tubes_watched = ['default']
      @tube_weights = {}
      @reserve_mode = nil

      _connect(tries: config.connect_retries.to_i + 1,
               retry_interval: config.connect_retry_interval)
    rescue Tuber::NotConnected
      raise # already carries its cause; do not wrap it twice
    rescue => ex
      _raise_not_connected!(ex)
    end

    # Send commands to beanstalkd server via connection.
    #
    # @param [Hash{String => String, Number}>] options Retained for compatibility
    # @param [String] command Beanstalkd command
    # @return [Array<Hash{String => String, Number}>] Beanstalkd command response
    # @example
    #   @conn = Tuber::Connection.new
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
    # @raise [Tuber::DeadlineSoonError] A reserved job's TTR is about to expire
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
        begin
          @connection.close
        rescue StandardError
          # A socket whose peer has already vanished can fail to close
          # cleanly. It is gone either way, and #reconnect! must not raise
          # on the way to replacing it.
        end
        @connection = nil
      end
    end

    # Re-establishes this connection and replays its tube state onto the new
    # socket: watched tubes with the weights they were watched with, the used
    # tube, and the reserve mode. Safe to call whether the current socket is
    # healthy, dropped, or already closed.
    #
    # This is the same healing the connection performs internally when a
    # command notices the socket has died, exposed for consumers that hold a
    # connection across an outage. Prefer it to building a new Tuber: a fresh
    # Connection makes a single connect attempt by default (see
    # Tuber::Configuration#connect_retries) and starts with no tube state, so
    # the caller has to re-watch and re-weight everything by hand.
    #
    # @param [Integer, nil] tries Maximum number of connect attempts, nil for
    #   the configured default (see Tuber::Configuration#connect_retries)
    # @param [Numeric, nil] retry_interval Seconds to wait between attempts,
    #   nil for the configured default
    # @return [Tuber::Connection] self
    # @raise [Tuber::NotConnected] Every connect attempt failed
    # @example
    #   begin
    #     job = @conn.transmit("reserve")
    #   rescue Tuber::NotConnected
    #     @conn.reconnect!   # watches, weights and reserve mode come back with it
    #     retry
    #   end
    #
    def reconnect!(tries: nil, retry_interval: nil)
      _reconnect(tries: tries || _connect_tries,
                 retry_interval: retry_interval || config.connect_retry_interval)
      _initialize_tubes
      self
    end

    # Returns string representation of job.
    #
    # @example
    #  @conn.inspect
    #
    def to_s
      "#<Tuber::Connection host=#{host.inspect} port=#{port.inspect}>"
    end
    alias :inspect :to_s

    # Records a tube as watched, along with the weight it was watched with.
    #
    # @param [String] tube_name Name of the tube now being watched
    # @param [Integer, nil] weight Weight passed to `watch`, nil for a plain watch
    def add_to_watched(tube_name, weight = nil)
      @tubes_watched << tube_name
      @tubes_watched.uniq!
      if weight
        @tube_weights[tube_name] = weight
      else
        @tube_weights.delete(tube_name)
      end
      @tubes_watched
    end

    def remove_from_watched(tube_name)
      @tube_weights.delete(tube_name)
      @tubes_watched.delete(tube_name)
    end

    # Replaces the watched tube list, dropping weights for tubes that are no
    # longer watched.
    def tubes_watched=(tube_names)
      @tubes_watched = tube_names
      @tube_weights.keep_if { |name, _| @tubes_watched.include?(name) }
      @tubes_watched
    end

    protected

    # Establish a connection based on beanstalk address.
    #
    # @return [Net::TCPSocket] connection for specified address.
    # @raise [Tuber::NotConnected] Could not connect to specified beanstalkd instance.
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
    # @raise [Tuber::UnexpectedResponse] Response from beanstalk command was an error status
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

    # Returns configuration options for tuber
    #
    # @return [Tuber::Configuration] configuration object
    def config
      Tuber.configuration
    end

    private

    # Replays this connection's tube state onto a freshly established socket.
    # Weights and reserve mode are per-connection server state that a new socket
    # resets, so a reconnect that only re-watched the tube names would silently
    # drop a weighted consumer back to FIFO. Order matters: watch, then drop
    # default, then set the mode.
    def _initialize_tubes
      if @tubes_watched != ['default'] || @tube_weights.any?
        tubes_watched.each do |t|
          weight = @tube_weights[t]
          transmit(weight ? "watch #{t} #{weight}" : "watch #{t}", init: false)
        end

        transmit("ignore default", init: false) unless @tubes_watched.include?('default')
      end

      transmit("use #{tube_used}", init: false) if @tube_used != 'default'

      transmit("reserve-mode #{@reserve_mode}", init: false) if @reserve_mode && @reserve_mode.to_s != 'fifo'
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
      _reconnect(tries: _connect_tries, retry_interval: retry_interval)
      _initialize_tubes if init
      raise ex unless retransmit
      retry
    rescue Tuber::DrainingError
      tries -= 1
      if tries.zero?
        close
        raise
      end
      sleep(retry_interval)
      retry
    end

    # Connect attempts to allow when healing a connection that was already
    # established. Never fewer than MAX_RETRIES, so the transparent retry
    # behaves exactly as it always has by default; raising connect_retries
    # lifts this with it, making one knob answer "how long should a client
    # ride out a server restart" for cold starts and reconnects alike.
    #
    # @return [Integer] maximum number of connect attempts
    def _connect_tries
      [MAX_RETRIES, config.connect_retries.to_i + 1].max
    end

    # Drops the current socket and connects again.
    #
    # @param [Integer] tries The maximum number of attempts to reconnect
    # @param [Numeric] retry_interval The time to wait before the next attempt
    # @raise [Tuber::NotConnected] Every attempt failed
    def _reconnect(tries: MAX_RETRIES, retry_interval: DEFAULT_RETRY_INTERVAL)
      close
      _connect(tries: tries, retry_interval: retry_interval)
    end

    # Connects, retrying while the server is refusing or unreachable.
    #
    # @param [Integer] tries The maximum number of connect attempts
    # @param [Numeric] retry_interval The time to wait between attempts
    # @raise [Tuber::NotConnected] Every attempt failed
    def _connect(tries: MAX_RETRIES, retry_interval: DEFAULT_RETRY_INTERVAL)
      establish_connection
    rescue *CONNECT_ERRORS => ex
      tries -= 1
      _raise_not_connected!(ex) if tries <= 0
      sleep(retry_interval || DEFAULT_RETRY_INTERVAL)
      retry
    end

    # The host provided by the TUBER_URL environment variable (or BEANSTALKD_URL,
    # honoured for compatibility with beanstalkd tooling), if available.
    #
    # @return [String] A server host address
    # @example
    #  ENV['TUBER_URL'] = "localhost:1212"
    #   # => 'localhost:1212'
    #
    def _host_from_env
      url = ENV['TUBER_URL'] || ENV['BEANSTALKD_URL']
      url.respond_to?(:length) && url.length > 0 && url.strip
    end

    # Packs a timeout value (in seconds) into a struct timeval binary string.
    # Supports fractional seconds (e.g., 0.5 => 500000 usec).
    def _timeval_for(timeout)
      sec = timeout.to_i
      usec = ((timeout.to_f - sec) * 1_000_000).to_i
      [sec, usec].pack('l_l_')
    end

    # Raises an error to be triggered when the connection has failed.
    #
    # The underlying error is named in the message as well as kept as the
    # exception's +cause+. A log line reading only "Connection to beanstalk
    # '...' is closed!" hides whether the server refused, timed out, or never
    # resolved — which is exactly what you want to know during an outage.
    #
    # Only the two callers that are genuinely inside a rescue pass a cause.
    # Defaulting to +$!+ would be wrong: a command issued from inside someone
    # else's rescue block would name whatever they were handling.
    #
    # @param [Exception, nil] cause The error that stopped the connect
    # @raise [Tuber::NotConnected] Beanstalkd is no longer connected
    def _raise_not_connected!(cause = nil)
      message = "Connection to beanstalk '#{@host}:#{@port}' is closed!"
      message += " (#{cause.class}: #{cause.message})" if cause && !cause.is_a?(Tuber::NotConnected)
      raise Tuber::NotConnected, message
    end

  end # Connection
end # Tuber
