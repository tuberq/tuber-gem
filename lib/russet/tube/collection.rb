# frozen_string_literal: true

class Russet
  # Represents collection of tube related commands.

  class Tubes
    include Enumerable

    # @!attribute client
    #   @return [Russet] returns the client instance
    attr_reader :client

    # Creates new tubes instance.
    #
    # @param [Russet] client The russet client instance.
    # @example
    #  Russet::Tubes.new(@client)
    #
    def initialize(client)
      @client = client
    end

    def last_used
      client.connection.tube_used
    end

    def last_used=(tube_name)
      client.connection.tube_used = tube_name
    end

    # Delegates transmit to the connection object.
    #
    # @see Russet::Connection#transmit
    def transmit(command, **options)
      client.connection.transmit(command, **options)
    end

    # Finds the specified beanstalk tube.
    #
    # @param [String] tube_name Name of the beanstalkd tube
    # @return [Russet::Tube] specified tube
    # @example
    #   @pool.tubes.find('tube2')
    #   @pool.tubes['tube2']
    #     # => <Russet::Tube name="tube2">
    #
    # @api public
    def find(tube_name)
      Tube.new(client, tube_name)
    end
    alias_method :[], :find

    # Reserves a ready job looking at all watched tubes.
    #
    # @param [Integer] timeout Number of seconds before timing out.
    # @param [Proc] block Callback to perform on the reserved job.
    # @yield [job] Reserved russet job.
    # @return [Russet::Job] Reserved russet job.
    # @example
    #   @client.tubes.reserve { |job| process(job) }
    #     # => <Russet::Job id=5 body="foo">
    #
    # @api public
    def reserve(timeout=nil, &block)
      res = transmit(
        timeout ? "reserve-with-timeout #{timeout}" : 'reserve')
      job = Job.new(client, res)
      block.call(job) if block_given?
      job
    end

    # Reserves a batch of ready jobs from watched tubes.
    #
    # Without a +timeout+ the call is non-blocking and may return an empty array.
    # With a positive +timeout+ it long-polls, blocking up to +timeout+ seconds
    # for the first job before draining whatever is ready, up to +count+.
    #
    # @param [Integer] count Maximum number of jobs to reserve
    # @param [Integer] timeout Seconds to long-poll for the first job (nil = non-blocking)
    # @return [Array<Russet::Job>] Array of reserved jobs (empty if none available)
    # @raise [Russet::DeadlineSoonError] A reserved job's TTR is about to expire
    # @example
    #   @client.tubes.reserve_batch(10)       # non-blocking
    #   @client.tubes.reserve_batch(10, 30)   # long-poll up to 30s
    #     # => [<Russet::Job id=1 body="foo">, ...]
    #
    # @api public
    def reserve_batch(count, timeout = nil)
      results = client.connection.reserve_batch(count, timeout)
      results.map { |res| Job.new(client, res) }
    end

    # Sets the reserve mode for the connection.
    #
    # @param [String, Symbol] mode The reserve mode ('weighted' or 'fifo')
    # @return [Hash] Response from beanstalkd
    # @example
    #   @client.tubes.reserve_mode(:weighted)
    #   @client.tubes.reserve_mode(:fifo)
    #
    # @api public
    def reserve_mode(mode)
      transmit("reserve-mode #{mode}")
    end

    # Reserves a specific job by its ID.
    #
    # @param [Integer, String] id The job ID to reserve
    # @return [Russet::Job, nil] The reserved job, or nil if not found
    # @example
    #   @client.tubes.reserve_job(123)
    #     # => <Russet::Job id=123 body="foo">
    #
    # @api public
    def reserve_job(id)
      res = transmit("reserve-job #{id}")
      Job.new(client, res)
    rescue Russet::NotFoundError
      nil
    end

    # Returns stats for a job group.
    #
    # @param [String] group The group name
    # @return [Russet::StatStruct] Struct of group stats
    # @example
    #   @client.tubes.stats_group('batch-1')
    #     # => #<StatStruct name="batch-1" ready=5 reserved=0 delayed=0 buried=0 waiting_jobs=0>
    #
    # @api public
    def stats_group(group)
      res = transmit("stats-group #{group}")
      StatStruct.from_hash(res[:body])
    end

    # List of all known beanstalk tubes.
    #
    # @return [Array<Russet::Tube>] List of all beanstalk tubes.
    # @example
    #   @client.tubes.all
    #     # => [<Russet::Tube name="tube2">, <Russet::Tube name="tube3">]
    #
    # @api public
    def all
      transmit('list-tubes')[:body].map do |tube_name|
        Tube.new(client, tube_name)
      end
    end

    # Calls the given block once for each known beanstalk tube, passing that element as a parameter.
    #
    # @return An Enumerator is returned if no block is given.
    # @example
    #   @pool.tubes.each {|t| puts t.name}
    #
    # @api public
    def each(&block)
      all.each(&block)
    end

    # List of watched beanstalk tubes.
    #
    # @return [Array<Russet::Tube>] List of watched beanstalk tubes.
    # @example
    #   @client.tubes.watched
    #     # => [<Russet::Tube name="tube2">, <Russet::Tube name="tube3">]
    #
    # @api public
    def watched
      last_watched = transmit('list-tubes-watched')[:body]
      client.connection.tubes_watched = last_watched.dup
      last_watched.map do |tube_name|
        Tube.new(client, tube_name)
      end
    end

    # Currently used beanstalk tube.
    #
    # @return [Russet::Tube] Currently used beanstalk tube.
    # @example
    #   @client.tubes.used
    #     # => <Russet::Tube name="tube2">
    #
    # @api public
    def used
      last_used = transmit('list-tube-used')[:id]
      Tube.new(client, last_used)
    end

    # Add specified beanstalkd tubes as watched.
    #
    # @param [*String] names Name of tubes to watch
    # @raise [Russet::InvalidTubeName] Tube to watch was invalid.
    # @example
    #   @client.tubes.watch('foo', 'bar')
    #
    # @api public
    def watch(*names, weight: nil)
      names.each do |t|
        cmd = weight ? "watch #{t} #{weight}" : "watch #{t}"
        transmit cmd
        client.connection.add_to_watched(t)
      end
    rescue BadFormatError => ex
      raise InvalidTubeName, "Tube in '#{ex.cmd}' is invalid!"
    end

    # Add specified beanstalkd tubes as watched and ignores all other tubes.
    #
    # @param [*String] names Name of tubes to watch
    # @raise [Russet::InvalidTubeName] Tube to watch was invalid.
    # @example
    #   @client.tubes.watch!('foo', 'bar')
    #
    # @api public
    def watch!(*names)
      old_tubes = watched.map(&:name) - names.map(&:to_s)
      watch(*names)
      ignore(*old_tubes)
    end

    # Ignores specified beanstalkd tubes.
    #
    # @param [*String] names Name of tubes to ignore
    # @example
    #   @client.tubes.ignore('foo', 'bar')
    #
    # @api public
    def ignore(*names)
      names.each do |w|
        transmit "ignore #{w}"
        client.connection.remove_from_watched(w)
      end
    end

    # Set specified tube as used.
    #
    # @param [String] tube Tube to be used.
    # @example
    #  @conn.tubes.use("some-tube")
    #
    def use(tube)
      return tube if last_used == tube
      transmit("use #{tube}")
      self.last_used = tube
    rescue BadFormatError
      raise InvalidTubeName, "Tube cannot be named '#{tube}'"
    end
  end # Tubes
end # Russet
