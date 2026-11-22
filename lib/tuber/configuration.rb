# frozen_string_literal: true

class Tuber
  class Configuration
    attr_accessor :default_put_delay   # default delay value to put a job
    attr_accessor :default_put_pri     # default priority value to put a job
    attr_accessor :default_put_ttr     # default ttr value to put a job
    attr_accessor :job_parser          # default job_parser to parse job body
    attr_accessor :job_serializer      # default serializer for job body
    attr_accessor :tuber_url           # default server url
    alias_method :beanstalkd_url,  :tuber_url   # compatibility with beaneater configs
    alias_method :beanstalkd_url=, :tuber_url=
    attr_accessor :connect_timeout     # TCP connect timeout in seconds
    attr_accessor :resolv_timeout      # DNS resolve timeout in seconds

    # Seconds to wait for a reply before raising IO::TimeoutError, beyond any
    # wait the command itself asks for: reserve-with-timeout and reserve-batch
    # get their own timeout added on, and a plain reserve has no deadline at
    # all. Needs Ruby >= 3.2 (IO#timeout); older Rubies fall back to
    # SO_RCVTIMEO, which Ruby's non-blocking sockets ignore from 3.0 on.
    attr_accessor :read_timeout

    # Seconds a write may block (the server not reading) before raising
    # IO::TimeoutError. Same Ruby caveat as read_timeout.
    attr_accessor :write_timeout

    # TCP keepalive, on by default. A blocked read waits on the server, so it
    # never learns the server is gone if the server's host vanished without
    # closing the connection: a reboot that takes the network down first, a
    # power cut, a partition. Keepalive probes an idle connection after
    # keepalive_idle seconds, every keepalive_interval seconds, and gives up
    # after keepalive_count unanswered probes, so the read fails (and the
    # connection heals) after about idle + interval * count seconds: 60 with
    # the defaults.
    attr_accessor :keepalive
    attr_accessor :keepalive_idle      # idle seconds before the first probe
    attr_accessor :keepalive_interval  # seconds between probes
    attr_accessor :keepalive_count     # unanswered probes before giving up

    # How hard a client tries to connect — "how long should this ride out a
    # server restart", in one knob.
    #
    # An established connection has always retried when it notices a dropped
    # socket (Tuber::Connection::MAX_RETRIES attempts), but the *initial*
    # connect got exactly one: a cold start during an outage — a web boot, a
    # fresh Tuber.new, a daemon rebuilding its client after an error — failed
    # where a held connection would have healed.
    #
    # Defaults to that single attempt, so nothing changes until you raise it.
    # Raising it covers the initial connect and lifts the reconnect budget of
    # connections already established along with it.
    attr_accessor :connect_retries          # extra connect attempts, 0 = one shot
    attr_accessor :connect_retry_interval   # seconds between connect attempts

    def initialize
      @default_put_delay   = 0
      @default_put_pri     = 65536
      @default_put_ttr     = 120
      @job_parser          = lambda { |body| body }
      @job_serializer      = lambda { |body| body }
      @tuber_url           = nil
      @connect_timeout     = nil
      @resolv_timeout      = nil
      @read_timeout        = nil
      @write_timeout       = nil
      @keepalive           = true
      @keepalive_idle      = 30
      @keepalive_interval  = 10
      @keepalive_count     = 3
      @connect_retries     = 0
      # Matches Tuber::Connection::DEFAULT_RETRY_INTERVAL, which is not loaded yet.
      @connect_retry_interval = 1
    end
  end # Configuration
end # Tuber