# frozen_string_literal: true

class Russet
  # Beanstalk tube which contains jobs which can be inserted, reserved, et al.
  class Tube

    # @!attribute name
    #   @return [String] name of the tube
    # @!attribute client
    #   @return [Russet] returns the client instance
    attr_reader :name, :client

    # Fetches the specified tube.
    #
    # @param [Russet] client The russet client instance.
    # @param [String] name The name for this tube.
    # @example
    #  Russet::Tube.new(@client, 'tube-name')
    #
    def initialize(client, name)
      @client = client
      @name = name.to_s
      @mutex = Mutex.new
    end

    # Delegates transmit to the connection object.
    #
    # @see Russet::Connection#transmit
    def transmit(command, options={})
      client.connection.transmit(command, **options)
    end

    # Inserts job with specified body onto tube.
    #
    # @param [String] body The data to store with this job.
    # @param [Hash{String => Integer}] options The settings associated with this job.
    # @option options [Integer] pri priority for this job
    # @option options [Integer] ttr time to respond for this job
    # @option options [Integer] delay delay for this job
    # @option options [String, Array] idp idempotency key, or [key, ttl] pair
    # @option options [String, Array] con concurrency key, or [key, limit] pair
    # @option options [String] grp group key for this job
    # @option options [String] aft after-group key (run after group completes)
    # @return [Hash{String => String, Number}] beanstalkd command response
    # @example
    #   @tube.put "data", pri: 1000, ttr: 10, delay: 5
    #   @tube.put "data", idp: "report", con: ["db", 3], grp: "batch-1", aft: "batch-0"
    #
    # @api public
    def put(body, options={})
      safe_use do
        serialized_body = config.job_serializer.call(body)

        options = {
          :pri   => config.default_put_pri,
          :delay => config.default_put_delay,
          :ttr   => config.default_put_ttr
        }.merge(options)

        cmd_options = "#{options[:pri]} #{options[:delay]} #{options[:ttr]} #{serialized_body.bytesize}"

        tags = []
        if options[:idp]
          tags << (options[:idp].is_a?(Array) ? "idp:#{options[:idp].join(':')}" : "idp:#{options[:idp]}")
        end
        if options[:con]
          tags << (options[:con].is_a?(Array) ? "con:#{options[:con].join(':')}" : "con:#{options[:con]}")
        end
        tags << "grp:#{options[:grp]}" if options[:grp]
        tags << "aft:#{options[:aft]}" if options[:aft]

        cmd_options = "#{cmd_options} #{tags.join(' ')}" if tags.any?
        transmit("put #{cmd_options}\r\n#{serialized_body}")
      end
    end

    # Peek at next job within this tube in given `state`.
    #
    # @param [String] state The job state to peek at (`ready`, `buried`, `delayed`)
    # @return [Russet::Job] The next job within this tube.
    # @example
    #  @tube.peek(:ready) # => <Russet::Job id=5 body=foo>
    #
    # @api public
    def peek(state)
      safe_use do
        res = transmit("peek-#{state}")
        Job.new(client, res)
      end
    rescue Russet::NotFoundError
      # Return nil if not found
      nil
    end

    # Reserves the next job from tube.
    #
    # @param [Integer] timeout Number of seconds before timing out
    # @param [Proc] block Callback to perform on reserved job
    # @yield [job] Job that was reserved.
    # @return [Russet::Job] Job that was reserved.
    # @example
    #  @tube.reserve # => <Russet::Job id=5 body=foo>
    #
    # @api public
    def reserve(timeout=nil, &block)
      client.tubes.watch!(self.name)
      client.tubes.reserve(timeout, &block)
    end

    # Kick specified number of jobs from buried to ready state.
    #
    # @param [Integer] bounds The number of jobs to kick.
    # @return [Hash{String => String, Number}] Beanstalkd command response
    # @example
    #   @tube.kick(5)
    #
    # @api public
    def kick(bounds=1)
      safe_use { transmit("kick #{bounds}") }
    end

    # Returns related stats for this tube.
    #
    # @return [Russet::StatStruct] Struct of tube related values
    # @example
    #  @tube.stats.current_jobs_delayed # => 24
    #
    # @api public
    def stats
      res = transmit("stats-tube #{name}")
      StatStruct.from_hash(res[:body])
    end

    # Pause the execution of this tube for specified `delay`.
    #
    # @param [Integer] delay Number of seconds to delay tube execution
    # @return [Array<Hash{String => String, Number}>] Beanstalkd command response
    # @example
    #   @tube.pause(10)
    #
    # @api public
    def pause(delay)
      transmit("pause-tube #{name} #{delay}")
    end

    # Atomically deletes all jobs from the tube.
    #
    # @return [Integer] Number of jobs flushed
    # @example
    #   @tube.flush # => 5
    #
    # @api public
    def flush
      res = transmit("flush-tube #{name}")
      res[:id].to_i
    end

    # Atomically deletes all buried jobs from the tube. Ready, delayed, and
    # reserved jobs are left untouched. (Tuber only.)
    #
    # @return [Integer] Number of buried jobs flushed
    # @example
    #   @tube.flush_buried # => 3
    #
    # @api public
    def flush_buried
      res = transmit("flush-buried #{name}")
      res[:id].to_i
    end

    # Clears all unreserved jobs in all states from the tube
    #
    # @example
    #   @tube.clear
    #
    def clear
      client.tubes.watch!(self.name)
      %w(delayed buried ready).each do |state|
        while job = self.peek(state.to_sym)
          begin
            job.delete
          rescue Russet::UnexpectedResponse, Russet::NotFoundError
            # swallow any issues
          end
        end
      end
      client.tubes.ignore(name)
    rescue Russet::NotIgnoredError
      # swallow any issues
    end

    # String representation of tube.
    #
    # @return [String] Representation of tube including name.
    # @example
    #  @tube.to_s # => "#<Russet::Tube name=foo>"
    #
    def to_s
      "#<Russet::Tube name=#{name.inspect}>"
    end
    alias :inspect :to_s

    protected

    # Transmits a beanstalk command that requires this tube to be set as used.
    #
    # @param [Proc] block Beanstalk command to transmit.
    # @return [Object] Result of block passed
    # @example
    #  safe_use { transmit("kick 1") }
    #    # => "Response to kick command"
    #
    def safe_use(&block)
      @mutex.lock
      client.tubes.use(self.name)
      yield
    ensure
      @mutex.unlock
    end

    # Returns configuration options for russet
    #
    # @return [Russet::Configuration] configuration object
    def config
      Russet.configuration
    end
  end # Tube
end # Russet
