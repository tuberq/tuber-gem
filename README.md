# Tuber

The Ruby client for [Tuber](https://github.com/tuberq/tuber), the simple, fast job queue server. One binary, zero dependencies — with unique/idempotent jobs, concurrency keys, job group pipelines, weighted tubes and batch operations built in.

Tuber (the server and this gem) is wire-compatible with [beanstalkd](https://github.com/beanstalkd/beanstalkd): point this client at a stock beanstalkd and everything except the Tuber-only extensions works unchanged. The gem is a fork of [beaneater](https://github.com/beanstalkd/beaneater), so it is also a drop-in beaneater replacement — see [Migrating from beaneater](#migrating-from-beaneater).

## Quick Start

```ruby
@tuber = Tuber.new('localhost:11300')

@tube = @tuber.tubes["my-tube"]
@tube.put '{"key": "foo"}', pri: 5
@tube.put '{"key": "bar"}', delay: 3

while @tube.peek(:ready)
  job = @tube.reserve
  puts job.body
  job.delete
end

@tuber.close
```

## Installation

Install the [tuber server](https://github.com/tuberq/tuber) (a single binary; `brew install tuberq/tuber/tuber`, Docker image `ghcr.io/tuberq/tuber`, or a [release binary](https://github.com/tuberq/tuber/releases)) — or use an existing beanstalkd — then add the gem:

```ruby
# Gemfile
gem 'tuber'
```

## Migrating from beaneater

Tuber forked from beaneater 1.1.4. The rename is the only breaking change — every
method, option and return value is unchanged. Two things to update:

```ruby
require 'beaneater'                        # before
require 'tuber'                           # after

@beanstalk = Beaneater.new('localhost:11300')  # before
@beanstalk = Tuber.new('localhost:11300')      # after
```

That includes the nested constants (`Beaneater::Job` → `Tuber::Job`), the error
classes (`Beaneater::NotConnected` → `Tuber::NotConnected`) and the configuration
block (`Beaneater.configure` → `Tuber.configure`). In most codebases a
case-sensitive `Beaneater` → `Tuber` and `beaneater` → `tuber` replacement is the
whole migration.

The `BEANSTALKD_URL` environment variable is still honoured (it's a beanstalkd
convention, not a beaneater one), though `TUBER_URL` now takes precedence.
Likewise `config.beanstalkd_url` remains as an alias for `config.tuber_url`.

## Usage

### Configuration

To setup advanced options for tuber, you can pass configuration options using:

```ruby
Tuber.configure do |config|
  # config.default_put_delay   = 0
  # config.default_put_pri     = 65536
  # config.default_put_ttr     = 120
  # config.job_parser          = lambda { |body| body }
  # config.job_serializer      = lambda { |body| body }
  # config.tuber_url           = 'localhost:11300'
  # config.connect_timeout     = nil
  # config.resolv_timeout      = nil
  # config.read_timeout        = nil
  # config.write_timeout       = nil
  # config.connect_retries        = 0
  # config.connect_retry_interval = 1
end
```

The above options are all defaults, so only include a configuration block if you need to make changes.

`connect_timeout` and `resolv_timeout` are passed through to `TCPSocket.new` on Ruby 3.0 and newer (ignored on Ruby < 3.0 for compatibility). `read_timeout` and `write_timeout` apply socket read and write timeouts via `setsockopt`.

### Connection

```ruby
@tuber = Tuber.new('10.0.1.5:11300')

# Or use ENV['TUBER_URL'] (or ENV['BEANSTALKD_URL'])
@tuber = Tuber.new

@tuber.close
```

#### Surviving a server restart

An established connection heals itself: when a command notices the socket has
died, the connection reconnects, replays its tube state, and re-sends the
command (except for the non-idempotent verbs — `put`, `delete`, `release`,
`bury`, `touch`, `kick` — where a blind re-send could duplicate a job or act on
a reservation that died with the old socket, so the original error is raised
for the caller to decide).

That healing gets three connect attempts a second apart. A server restart
typically takes longer, so give the client a budget that outlasts it:

```ruby
Tuber.configure do |config|
  config.connect_retries        = 15   # extra attempts, 0 = a single attempt
  config.connect_retry_interval = 1    # seconds between them
end
```

`connect_retries` covers both a cold start (`Tuber.new` while the server is
down) and reconnects on a client you already hold. It defaults to `0` — a
single attempt — which is the historical behaviour.

When a command does surface `Tuber::NotConnected`, heal the client you have
rather than building a new one:

```ruby
begin
  job = @tuber.tubes.reserve
rescue Tuber::NotConnected
  @tuber.reconnect!   # watched tubes, their weights, the used tube and the
  retry               # reserve mode all come back with it
end
```

A fresh `Tuber.new` starts with no tube state, so a worker that reconnects that
way has to re-watch and re-weight every tube by hand — and will silently fall
back to FIFO if it forgets the reserve mode. `reconnect!` replays all of it.
It takes the same budget as the config, overridable per call:
`@tuber.reconnect!(tries: 30, retry_interval: 2)`.

### Tubes

Tubes are named work queues. Jobs are `put` into the used tube and `reserve`d from watched tubes. Each tube has a _ready_, _delayed_, and _buried_ queue.

```ruby
@tube = @tuber.tubes.find("some-tube")

# Watch tubes for reserving jobs
@tuber.tubes.watch!('some-tube')        # watch only these tubes
@tuber.tubes.watch('another-tube')       # append to watch list
@tuber.tubes.ignore('some-tube')         # stop watching

# List tubes
@tuber.tubes.all       # => [<Tube name='foo'>, <Tube name='bar'>]
@tuber.tubes.used      # => <Tube name='bar'>
@tuber.tubes.watched   # => [<Tube name='foo'>]

# Manage tubes
@tube.pause(3)        # pause for 3 seconds
@tube.clear           # delete all jobs
@tube.flush           # delete all jobs, returns count
@tube.flush_buried    # delete only buried jobs (Tuber only), returns count
```

Each client manages two separate concerns: **use**/**using** controls where `put` places jobs, and **watch**/**watching** controls where `reserve` takes jobs from. These are fully orthogonal.

### Jobs

A job has a body (string) and metadata. The typical lifecycle:

```
   put            reserve               delete
  -----> [READY] ---------> [RESERVED] --------> *poof*
```

Jobs are in one of three states:

| State   | Description |
| ------- | ----------- |
| ready   | Waiting to be reserved and processed. |
| delayed | Waiting to become ready after a delay. |
| buried  | Held aside after failure, waiting to be kicked. |

#### Inserting jobs

```ruby
@tube.put "job-data-here"
@tube.put({foo: 'bar'}.to_json)
@tube.put "job-data-here", pri: 1000, delay: 50, ttr: 200
```

- **pri** — integer < 2^32, lower values run first (default: 65536)
- **delay** — seconds to wait before the job becomes ready (default: 0)
- **ttr** — time to run, seconds a worker has to finish the job (default: 120)

#### Reserving and processing jobs

```ruby
job = @tuber.tubes.reserve      # blocks until a job is available
job = @tuber.tubes.reserve(5)   # wait up to 5 seconds

puts job.body
puts job.tube
puts job.stats.state  # => 'reserved'

job.touch    # extend ttr
job.delete   # success
job.release delay: 5  # retry later
job.bury     # set aside for inspection
```

#### Peeking and kicking

```ruby
@tuber.jobs.find(123)       # peek at a specific job
@tube.peek(:ready)              # peek at next ready job
@tube.peek(:buried)
@tube.peek(:delayed)

@tuber.tubes['some-tube'].kick(3)  # kick 3 buried jobs back to ready
```

#### Automatic processing

Register handlers for tubes and let `process!` loop over incoming jobs:

```ruby
@tuber.jobs.register('some-tube', retry_on: [SomeError]) do |job|
  do_something(job)
end

@tuber.jobs.register('other-tube') do |job|
  do_something_else(job)
end

@tuber.jobs.process!
```

The loop reserves a job, calls the matching handler, then: deletes on success, releases on `retry_on` errors, and buries on other exceptions. Raise `AbortProcessingError` to stop the loop.

### Job Dependencies (Tuber only)

When using [Tuber](https://github.com/tuberq/tuber), you can group related jobs and chain dependent work using `group:` and `after:` options on `put`. After-jobs are held until every job in the group they depend on has been deleted:

```ruby
# Fan-out: enqueue grouped work
@tube.put "import-row-1", group: "import"
@tube.put "import-row-2", group: "import"

# Fan-in: this job waits until all "import" jobs are deleted
@tube.put "send-summary", after: "import"
```

Chain stages together by combining `after:` and `group:` on the same job to build a simple DAG pipeline:

```ruby
@tube.put "row-1", group: "extract"
@tube.put "row-2", group: "extract"
@tube.put "transform", after: "extract", group: "transform"
@tube.put "load",      after: "transform"
```

Here `transform` waits for the extract group to finish, then becomes part of the `transform` group. `load` waits for `transform` to complete.

Buried jobs block group completion — kick them to let the group finish. Group names are global and can span multiple tubes.

### Unique Jobs / Idempotency (Tuber only)

Prevent duplicate jobs with the `idempotency:` option. If a job with the same key already exists in the tube, the original job is returned instead of creating a duplicate:

```ruby
@tube.put "send-report", idempotency: "daily-report"
# => <Tuber::Job id=1 body="send-report">

@tube.put "send-report", idempotency: "daily-report"
# => <Tuber::Job id=1 body="send-report">  (same job, no duplicate created)
```

The key is scoped to the tube and cleared when the job is deleted, so the same key can be reused afterwards.

Add a cooldown TTL to keep deduplicating for N seconds after deletion — useful for preventing rapid resubmission:

```ruby
@tube.put "send-report", idempotency: "daily-report", idempotency_ttl: 300
```

### Concurrency Keys (Tuber only)

Limit parallel processing of related jobs. When a job with a concurrency key is reserved, other ready jobs sharing the same key are hidden from `reserve` until the reservation ends:

```ruby
# Only one job per user can be processed at a time
@tube.put "process-user-42", concurrency: "user-42"
@tube.put "process-user-42-again", concurrency: "user-42"
```

The second job won't be reserved until the first is deleted, released, or buried. Set a higher limit to allow N concurrent reservations:

```ruby
# Allow up to 3 concurrent API jobs
@tube.put "api-call-1", concurrency: "api", concurrency_limit: 3
@tube.put "api-call-2", concurrency: "api", concurrency_limit: 3
```

### Weighted Tubes (Tuber only)

By default, `reserve` picks the highest-priority job across all watched tubes. Switch to weighted mode to select tubes randomly in proportion to their weight:

```ruby
@tuber.tubes.watch('email')
@tuber.tubes.watch('notifications', weight: 2)
@tuber.tubes.watch('batch-jobs', weight: 6)

@tuber.tubes.reserve_mode(:weighted)

job = @tuber.tubes.reserve  # batch-jobs selected 6x as often as email
```

Tubes default to weight 1. Switch back with `reserve_mode(:fifo)`.

Weights and reserve mode are per-connection server state. The client remembers
both and replays them if the connection has to be re-established, so a worker
that heals across a server blip keeps reserving by weight.

### Batch Reserve (Tuber only)

Reserve multiple jobs atomically in a single call:

```ruby
jobs = @tuber.tubes.reserve_batch(10)  # up to 10 jobs

jobs.each do |job|
  process(job)
  job.delete
end
```

By default `reserve_batch` is non-blocking — it returns whatever is ready
immediately, possibly an empty array. Pass a timeout (in seconds) to long-poll
instead: the call blocks until the first job arrives, then drains everything
ready up to `count`, or returns an empty array when the timeout elapses. This
avoids hot-looping a worker on empty polls.

```ruby
jobs = @tuber.tubes.reserve_batch(10, 30)  # block up to 30s for the first job
```

While blocked, a positive-timeout batch reserve may raise
`Tuber::DeadlineSoonError` if one of the connection's already-reserved jobs
is about to hit its TTR — service that job, then reserve again.

### Batch Touch (Tuber 0.12.0+)

A batch reserve starts the TTR clock on every job at the same instant, but a
worker processes them serially — so the tail of a large batch can expire and
return to the queue while the worker is still busy. `touch_all` extends the TTR
of every job the connection currently holds in a single command:

```ruby
jobs = @tuber.tubes.reserve_batch(10)

jobs.each do |job|
  process(job)
  job.delete
  @tuber.jobs.touch_all   # heartbeat whatever is still held
end
```

No ids are sent: the server tracks the reserved set per connection, so jobs
already deleted, released, buried or lost to a TTR timeout are simply absent.
Each job keeps its own TTR — deadlines are extended individually, not levelled
onto a common value.

The return value is how many jobs the connection *actually* still holds. A count
lower than expected means jobs hit their TTR and went back to the queue while the
worker was busy — otherwise invisible, since nothing notifies a worker that it
lost a job.

### Stats

```ruby
@tuber.stats                            # server-wide stats
@tuber.tubes['some-tube'].stats         # tube stats
@tuber.jobs[some_job_id].stats          # job stats
```

## Configuration

```ruby
Tuber.configure do |config|
  config.default_put_delay   = 0
  config.default_put_pri     = 65536
  config.default_put_ttr     = 120
  config.job_parser          = lambda { |body| body }
  config.job_serializer      = lambda { |body| body }
  config.tuber_url           = 'localhost:11300'

  # Connect attempts; see "Surviving a server restart" above.
  config.connect_retries        = 0
  config.connect_retry_interval = 1
end
```

The `job_serializer` is applied to every `put` body — useful for automatic JSON encoding:

```ruby
Tuber.configure do |config|
  config.job_serializer = lambda { |body| JSON.dump(body) }
end
```

## Error Handling

| Error                         | Description |
| ----------------------------- | ----------- |
| Tuber::NotConnected       | Cannot connect to the server. |
| Tuber::InvalidTubeName    | Tube name is not valid. |
| Tuber::NotFoundError      | Job or tube not found. |
| Tuber::TimedOutError      | Reserve timed out. |
| Tuber::JobNotReserved     | Action requires a reserved job. |
| Tuber::OutOfStorageError  | A persistent Tuber's disk budget (`--max-storage-bytes`) is spent. |

See the [Tuber protocol](https://github.com/tuberq/tuber/blob/main/docs/protocol.md) (a superset of the [beanstalk protocol](https://github.com/beanstalkd/beanstalkd/blob/master/doc/protocol.txt)) for additional error types.

## Resources

 * [Tuber](https://github.com/tuberq/tuber)
 * [Tuber protocol](https://github.com/tuberq/tuber/blob/main/docs/protocol.md)
 * [Tuber on RubyGems](https://rubygems.org/gems/tuber)
 * [Beanstalkd](https://github.com/beanstalkd/beanstalkd) and the [beanstalk protocol](https://github.com/beanstalkd/beanstalkd/blob/master/doc/protocol.txt)
 * [Backburner](https://github.com/nesquena/backburner) — Ruby job queue for Rails/Sinatra

## Contributors

Tuber is maintained by [Dan Milne](https://github.com/dkam), and builds on the work of
everyone who wrote beaneater, from which it is forked:

 - [Nico Taing](https://github.com/Nico-Taing) - Creator and co-maintainer of beaneater
 - [Nathan Esquenazi](https://github.com/nesquena) - Contributor and co-maintainer
 - [Keith Rarick](https://github.com/kr) - Much code inspired and adapted from beanstalk-client
 - [Vidar Hokstad](https://github.com/vidarh) - Replaced telnet with correct TCP socket handling
 - [Andreas Loupasakis](https://github.com/alup) - Improve test coverage, improve job configuration
