# frozen_string_literal: true

class Tuber
  # Raises when a beanstalkd instance is no longer accessible.
  class NotConnected < RuntimeError; end
  # Raises when the tube name specified is invalid.
  class InvalidTubeName < RuntimeError; end
  # Raises when a job has not been reserved properly.
  class JobNotReserved < RuntimeError; end

  # Abstract class for errors that occur when a command does not complete successfully.
  class UnexpectedResponse < RuntimeError
    # Set of status states that are considered errors
    ERROR_STATES = %w(OUT_OF_MEMORY OUT_OF_STORAGE INTERNAL_ERROR
      BAD_FORMAT UNKNOWN_COMMAND JOB_TOO_BIG DRAINING
      TIMED_OUT DEADLINE_SOON NOT_FOUND NOT_IGNORED EXPECTED_CRLF)

    # @!attribute status
    #   @return [String] returns beanstalkd response status
    #   @example @ex.status # => "NOT_FOUND"
    # @!attribute cmd
    #   @return [String] returns beanstalkd request command
    #   @example @ex.cmd # => "stats-job 23"
    attr_reader :status, :cmd

    # Initialize unexpected response error
    #
    # @param [Tuber::UnexpectedResponse] status Unexpected response object
    # @param [String] cmd Beanstalkd request command
    # @param [String, nil] message Overrides the default "Response failed with: <status>"
    #
    # @example
    #   Tuber::UnexpectedResponse.new(NotFoundError, 'bury 123')
    #
    def initialize(status, cmd, message = nil)
      @status, @cmd = status, cmd
      super(message || "Response failed with: #{status}")
    end

    # Translate beanstalkd error status to ruby Exeception
    #
    # @param [String] status Beanstalkd error status
    # @param [String] cmd Beanstalkd request command
    #
    # @return [Tuber::UnexpectedResponse] Exception for the status provided
    # @example
    #   Tuber::UnexpectedResponse.new('NOT_FOUND', 'bury 123')
    #
    def self.from_status(status, cmd)
      error_klazz_name = status.split('_').map { |w| w.capitalize }.join
      error_klazz_name << "Error" unless error_klazz_name =~ /Error$/
      error_klazz = Tuber.const_get(error_klazz_name)
      error_klazz.new(status, cmd)
    end
  end

  # Raises when the beanstalkd instance runs out of memory
  class OutOfMemoryError < UnexpectedResponse; end
  # Raises when a persistent Tuber server's disk budget (--max-storage-bytes) is spent
  class OutOfStorageError < UnexpectedResponse; end
  # Raises when the beanstalkd instance is draining and new jobs cannot be inserted
  class DrainingError < UnexpectedResponse; end
  # Raises when the job or tube cannot be found
  class NotFoundError < UnexpectedResponse; end
  # Raises when the job reserved is going to be released within a second.
  class DeadlineSoonError < UnexpectedResponse; end
  # Raises when a beanstalkd has an internal error.
  class InternalError < UnexpectedResponse; end
  # Raises when a command was not properly formatted.
  class BadFormatError < UnexpectedResponse; end
  # Raises when a command was sent that is unknown.
  class UnknownCommandError < UnexpectedResponse; end
  # Raises when command does not have proper CRLF suffix.
  class ExpectedCrlfError < UnexpectedResponse; end
  # Raises when the body of a job was too large.
  class JobTooBigError < UnexpectedResponse; end
  # Raises when a job was attempted to be reserved but the timeout occurred.
  class TimedOutError < UnexpectedResponse; end
  # Raises when a tube could not be ignored because it is the last watched tube.
  class NotIgnoredError < UnexpectedResponse; end

  # Raises when a Tuber server refuses a schedule sync (see Tuber::Schedules#sync).
  #
  # Unless #applied? is true, nothing changed: the owner's previous schedule
  # is still the one in effect.
  class ScheduleSyncError < UnexpectedResponse
    # @!attribute owner
    #   @return [String] the owner whose sync was refused
    # @!attribute entry
    #   @return [String, nil] the entry tuber refused, nil when it refused the
    #     sync as a whole (on begin or commit)
    attr_reader :owner, :entry

    # @param [String] status The server's reply, e.g. "BAD_SCHEDULE"
    # @param [String] cmd The command it refused
    # @param [String] owner The owner being synced
    # @param [String, nil] entry The refused entry's name
    def initialize(status, cmd, owner:, entry: nil)
      @owner, @entry = owner, entry
      super(status, cmd, describe(status, cmd, owner, entry))
    end

    # True when the new set is live despite the error: the commit took effect
    # in memory but tuber couldn't write it to disk (INTERNAL_ERROR). A tuber
    # restart before the next successful sync brings back the previous set.
    #
    # @return [Boolean]
    def applied?
      cmd == 'schedule-commit' && status == 'INTERNAL_ERROR'
    end

    private

    def describe(status, cmd, owner, entry)
      if entry
        "tuber refused schedule #{entry.inspect} (#{status}): #{cmd}. " \
          "Nothing changed: #{owner.inspect}'s previous schedule is still in effect."
      elsif cmd == 'schedule-commit' && status == 'INTERNAL_ERROR'
        "#{owner.inspect}'s new schedule is live, but tuber couldn't write it to disk " \
          "(INTERNAL_ERROR). A tuber restart before the next successful sync brings back the previous one."
      elsif cmd == 'schedule-commit'
        "tuber refused #{owner.inspect}'s schedule on commit (#{status}). " \
          "Nothing changed: the previous schedule is still in effect."
      elsif status == 'UNKNOWN_COMMAND'
        "this server has no recurring schedules (UNKNOWN_COMMAND to #{cmd.inspect}): " \
          "it is beanstalkd, or a tuber older than the scheduler."
      else
        "tuber refused to begin a schedule sync for #{owner.inspect} (#{status})."
      end
    end
  end
end
