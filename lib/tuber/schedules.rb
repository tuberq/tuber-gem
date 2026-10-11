# frozen_string_literal: true

require 'time'

class Tuber
  # Recurring schedules held by a Tuber server (beanstalkd has none): entries
  # the server puts into a tube at the times a spec names, so an app needs no
  # scheduler process of its own. A fire is an ordinary put — workers reserve
  # the job as they would any other.
  #
  # An app owns its entries under a name of its choosing, the *owner*, and
  # replaces the whole set with one #sync: entries it no longer sends are
  # removed, an edited one is updated in place, and an unchanged one keeps its
  # next fire. Every replica may sync; an identical set changes nothing.
  #
  # @example
  #   tuber.schedules.sync("splat") do |s|
  #     s.add "data_retention", tube: "splat.maintenance",
  #           cron: "0 2 * * *", zone: "Australia/Melbourne",
  #           body: { class: "DataRetentionJob", args: [] }.to_json, con: "maintenance"
  #     s.add "monitor_evaluation", tube: "splat.checkins", every: 60,
  #           idp: "monitor_evaluation", body: { class: "MonitorEvaluationJob", args: [] }.to_json
  #   end
  #   # => #<struct Tuber::Schedules::SyncResult added=2, changed=0, removed=0, unchanged=0>
  #
  class Schedules
    # What a committed sync did to the owner's entries.
    #
    # If the connection dropped and the sync was re-run, the counts describe
    # the last attempt only: a drop after the first attempt's commit landed
    # makes the re-run report every entry as unchanged.
    SyncResult = Struct.new(:added, :changed, :removed, :unchanged)

    # One staged entry: its name, the `schedule-put` arguments, and the
    # serialized body.
    Entry = Struct.new(:name, :line, :body)

    # Owners, entry names and tubes follow the server's tube-name rules.
    NAME = %r{\A[A-Za-z0-9+/;.$_()][A-Za-z0-9\-+/;.$_()]*\z}

    # @!attribute client
    #   @return [Tuber] returns the client instance
    attr_reader :client

    # @param [Tuber] client The tuber client instance.
    def initialize(client)
      @client = client
    end

    # Replaces +owner+'s entries with the ones the block adds, in one step.
    #
    # Send the complete schedule every time: an entry left out is deleted.
    #
    # Sync when a new release starts — a release step, or once at process
    # boot — not on reconnect. Tuber keeps schedules across its own restarts
    # (with -b), and during a rolling deploy an old process re-syncing would
    # put back what the new release removed.
    #
    # @param [String] owner The app's name for its set of entries
    # @param [Boolean] allow_empty A sync with no entries removes all of the
    #   owner's entries. Refused unless this is true, since an app that loaded
    #   an empty config by mistake would otherwise wipe its schedule.
    # @yieldparam [Tuber::Schedules::Builder] s Call +s.add+ once per entry
    # @return [Tuber::Schedules::SyncResult]
    # @raise [Tuber::ScheduleSyncError] The server refused an entry or the
    #   sync. Nothing changed unless the error's #applied? says otherwise.
    # @raise [ArgumentError] An entry is malformed, or the set is empty
    #   without +allow_empty+. Nothing is sent.
    # @raise [Tuber::NotConnected] The sync's own connection couldn't be
    #   made (see Tuber::Configuration#connect_retries)
    # @api public
    def sync(owner, allow_empty: false)
      owner = Schedules.name!("owner", owner)
      builder = Builder.new
      yield builder if block_given?
      if builder.entries.empty? && !allow_empty
        raise ArgumentError, "refusing to sync no entries for #{owner.inspect}: that removes " \
                             "all of its schedules. Pass allow_empty: true if that's meant."
      end

      # A connection of its own: a blocking reserve on the client's connection
      # can't hold the sync up, and an error partway, which can leave the
      # server mid-sync with a reply unread, is cleaned up by closing it.
      connection = Connection.new(client.connection.address)
      begin
        connection.schedule_sync(owner, builder.entries)
      ensure
        connection.close
      end
    end

    # The entries the server holds, as [owner, name] pairs.
    #
    # @param [String, nil] owner Only this owner's entries
    # @return [Array<Array(String, String)>]
    # @example
    #   tuber.schedules.list("splat") # => [["splat", "data_retention"], ["splat", "monitor_evaluation"]]
    # @api public
    def list(owner = nil)
      owner = Schedules.name!("owner", owner) if owner
      yaml = client.connection.transmit_raw(owner ? "list-schedules #{owner}" : "list-schedules")
      yaml.each_line.grep(/\A- /).map { |line| line.chomp[2..-1].split(' ', 2) }
    end

    # One entry's definition, next three fires, last fire and counters.
    #
    # Times are Time objects at the entry's own zone offset, nil when there is
    # none yet; counters are Integers. +buried_streak+ above 0 means fires are
    # deduplicating against a buried job (through +idp:+) and queueing nothing.
    #
    # @param [String] owner The entry's owner
    # @param [String] name The entry's name
    # @return [Tuber::StatStruct, nil] nil if there is no such entry
    # @example
    #   stats = tuber.schedules.stats("splat", "data_retention")
    #   stats.next_fire       # => 2026-10-12 02:00:00 +1100
    #   stats["next-fire-2"]  # => 2026-10-13 02:00:00 +1100
    #   stats.buried_streak   # => 0
    # @api public
    def stats(owner, name)
      owner = Schedules.name!("owner", owner)
      name = Schedules.name!("name", name)
      yaml = client.connection.transmit_raw("stats-schedule #{owner} #{name}")
      stats = yaml.each_line.with_object({}) do |line, hash|
        key, value = line.chomp.split(': ', 2)
        hash[key] = Schedules.stat_value(value) if value
      end
      StatStruct.from_hash(stats)
    rescue Tuber::NotFoundError
      nil
    end

    # String representation of the schedules collection.
    def to_s
      "#<Tuber::Schedules>"
    end
    alias :inspect :to_s

    # Checks an owner, entry name or tube against tube-name rules.
    #
    # @return [String] The name, a Symbol converted
    # @raise [ArgumentError] It breaks them
    # @api private
    def self.name!(what, value)
      value = value.to_s if value.is_a?(Symbol)
      return value if value.is_a?(String) && value.bytesize <= 200 && value.match?(NAME)
      raise ArgumentError, "invalid schedule #{what} #{value.inspect}: up to 200 bytes of letters, " \
                           "digits and - + / ; . $ _ ( ), not starting with -"
    end

    # Converts one stats-schedule value by how tuber writes it: a quoted value
    # is a String, `""` meaning none (nil); bare digits are a counter; any
    # other bare value is a time.
    #
    # @api private
    def self.stat_value(value)
      if value.start_with?('"')
        string = value.delete_prefix('"').delete_suffix('"')
        string.empty? ? nil : string
      elsif value.match?(/\A\d+\z/)
        value.to_i
      else
        begin
          Time.iso8601(value)
        rescue ArgumentError
          value # a field newer than this gem; better raw than an error
        end
      end
    end

    # Collects the entries of one sync. Nothing is sent until the block ends,
    # and nothing at all if an #add raises.
    class Builder
      # @!attribute entries
      #   @return [Array<Tuber::Schedules::Entry>] the entries added so far
      attr_reader :entries

      def initialize
        @entries = []
      end

      # Adds one entry. Give exactly one of +cron:+, +every:+ or +spec:+.
      #
      # @param [String] name The entry's name, unique within the owner. Keep
      #   it stable: a renamed entry is a removal plus an addition.
      # @param [String] tube The tube each fire puts into
      # @param [String] body The job body each fire puts, passed through
      #   Tuber.configuration.job_serializer as for Tube#put
      # @param [String] cron 5-field cron (`"0 2 * * *"`) or a macro
      #   (`"@daily"`), optionally followed by an IANA zone
      # @param [String] zone IANA zone for +cron+ (default UTC)
      # @param [Integer, String] every Interval, aligned to the Unix epoch:
      #   seconds, or `"10m"`, `"1h"`, `"1d"`
      # @param [Integer, String] offset Shift for +every+, e.g. `"5m"`
      # @param [String] spec The spec as tuber reads it, instead of the above
      # @param [Integer] pri Priority; defaults as for a put
      # @param [Integer] delay Delay of each fire's job; defaults as for a put
      # @param [Integer] ttr TTR of each fire's job; defaults as for a put
      # @param [String, Array] idp Idempotency key, or [key, ttl], as for a
      #   put. A fire is skipped while the previous fire's job is still in
      #   the tube — buried included, so a buried job stops the entry until
      #   it is kicked or deleted.
      # @param [String, Array] con Concurrency key, or [key, limit], as for a put
      # @param [String] grp Group key, as for a put
      # @param [String] aft After-group key, as for a put
      # @param [Symbol, Integer, false] catchup What a tick missed while
      #   tuber was down does: `:once` (the default) fires once for the gap;
      #   an Integer fires that once only if it is at most that many seconds
      #   stale; `:never`, `false` or 0 never fires it.
      # @return [self]
      # @raise [ArgumentError] Something tuber would refuse, or that would
      #   break the line
      def add(name, tube:, body:, cron: nil, zone: nil, every: nil, offset: nil, spec: nil,
              pri: nil, delay: nil, ttr: nil, idp: nil, con: nil, grp: nil, aft: nil, catchup: :once)
        name = Schedules.name!("name", name)
        tube = Schedules.name!("tube", tube)
        raise ArgumentError, "schedule #{name.inspect} added twice" if @entries.any? { |e| e.name == name }

        config = Tuber.configuration
        serialized = config.job_serializer.call(body)
        unless serialized.is_a?(String)
          raise ArgumentError, "the body of schedule #{name.inspect} is a #{serialized.class}, not a String: " \
                               "serialize it, or set Tuber.configuration.job_serializer"
        end
        serialized = serialized.b

        words = [name, tube,
                 Integer(pri || config.default_put_pri),
                 Integer(delay || config.default_put_delay),
                 Integer(ttr || config.default_put_ttr),
                 serialized.bytesize]
        words.concat(tags(name, idp: idp, con: con, grp: grp, aft: aft, catchup: catchup))
        words << spec_text(name, cron: cron, zone: zone, every: every, offset: offset, spec: spec)
        @entries << Entry.new(name, words.join(' '), serialized)
        self
      end

      private

      def spec_text(name, cron:, zone:, every:, offset:, spec:)
        given = { spec: spec, cron: cron, every: every }.compact
        unless given.size == 1
          raise ArgumentError, "schedule #{name.inspect} needs exactly one of cron:, every: or spec: " \
                               "(got #{given.empty? ? 'none' : given.keys.join(', ')})"
        end
        raise ArgumentError, "schedule #{name.inspect}: zone: goes with cron:" if zone && !cron
        raise ArgumentError, "schedule #{name.inspect}: offset: goes with every:" if offset && !every

        text = if every
          ["every #{duration(every)}", (offset && "offset #{duration(offset)}")].compact.join(' ')
        elsif cron
          [cron, zone].compact.join(' ')
        else
          spec
        end
        # Tags end at the first word without a colon, so a spec can't have one.
        if !text.is_a?(String) || text.strip.empty? || text.match?(/[\r\n:]/)
          raise ArgumentError, "invalid spec #{text.inspect} for schedule #{name.inspect}"
        end
        text.strip
      end

      def duration(value)
        value.is_a?(Integer) ? "#{value.to_i}s" : value.to_s
      end

      def tags(name, catchup:, **options)
        tags = Tube.tags(options)
        case catchup
        when :once, nil then nil
        when :never, false then tags << "catchup:0"
        when Integer
          raise ArgumentError, "catchup: can't be negative (schedule #{name.inspect})" if catchup.negative?
          tags << "catchup:#{catchup.to_i}"
        else
          raise ArgumentError, "invalid catchup: #{catchup.inspect} for schedule #{name.inspect} " \
                               "(:once, :never, or a number of seconds)"
        end
        tags.each do |tag|
          next if tag.match?(/\A[a-z]+:\S+\z/)
          raise ArgumentError, "invalid tag #{tag.inspect} for schedule #{name.inspect}: " \
                               "keys can't be empty or contain whitespace"
        end
        tags
      end
    end
  end # Schedules
end # Tuber
