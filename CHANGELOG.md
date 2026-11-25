# CHANGELOG for the tuber gem

The tuber gem is a fork of [beaneater](https://github.com/beanstalkd/beaneater), taken at
beaneater 1.1.4. Entries from 1.1.4 down are beaneater's history, kept for reference.
(0.0.1 was an empty placeholder published to claim the gem name.)

## 0.9.0 (November 25 2026)

A `process!` loop that respects its handler and talks to the server less. A
handler that released or buried its own job used to have that silently undone,
and the loop asked the server about jobs it had just dealt with.

* Fix `process!` deleting a job its handler had already released, buried or deleted. Tuber and beanstalkd both delete ready, delayed and buried jobs, so a retry the handler scheduled was lost, and a job it buried vanished. A handler that deleted its own job and called `stop!` left the loop blocked in `reserve`. The loop now leaves a job its handler settled alone. Behaviour change: a handler that releases or buries its job keeps that job. (#5)
* `process!` sends only the commands it needs. A successful job takes `reserve`, `stats-job` and `delete`, one fewer than before. A job released for a retry takes four commands instead of eight, and a buried one four instead of six. (#3)
* `Job#release` fetched the job's stats twice, even when given `:pri` and `:delay`. It now fetches them once, and not at all when given both. `Job#bury` no longer fetches them when given `:pri`. (#3)
* Add `Job#settled?`, true once this object has deleted, released or buried the job. It is known locally, without asking the server. (#3)

## 0.8.0 (November 22 2026)

Surviving a server whose host vanishes. A consumer blocked in `reserve` used to
wait forever on a connection whose server had gone without closing it, as after
a host reboot. It now notices in about a minute, reconnects and carries on.

* Turn on TCP keepalive by default, so a consumer blocked in `reserve` notices a server whose host vanished without closing the connection (a reboot that takes the network down first, a power cut, a partition) in about 60 seconds, instead of waiting forever on a half-open socket. Tune it with `keepalive_idle` (30), `keepalive_interval` (10) and `keepalive_count` (3), or turn it off with `keepalive = false`. (#2)
* Heal the connection after `Errno::ETIMEDOUT` (a failed keepalive) and `IO::TimeoutError` (a read or write timeout), as for a dropped socket: an idempotent command such as `reserve` reconnects and is re-sent, and the caller never sees the error. A timeout is re-sent at most once. A second one on a fresh socket means the server is up but not answering, and is raised.
* Fix `read_timeout` and `write_timeout`, which did nothing on Ruby 3.0 and newer: Ruby's sockets are non-blocking from 3.0 on, and ignore `SO_RCVTIMEO`/`SO_SNDTIMEO`. They now use `IO#timeout` on Ruby 3.2 and newer. Older Rubies keep the `setsockopt` fallback. Behaviour change: with `read_timeout` set, a reply that takes longer now raises `IO::TimeoutError` after one re-send. `reserve-with-timeout` and `reserve_batch` with a timeout get their own timeout added to `read_timeout`, and a plain `reserve` has no read deadline.

## 0.7.0 (October 11 2026)

Recurring schedules. A Tuber with the scheduler runs an app's recurring jobs
itself, so the app can drop its scheduler process. This release adds the client
side. Nothing changes for code that doesn't call it.

* Add `Tuber#schedules`: `sync(owner) { |s| s.add ... }` replaces an owner's whole set of entries in one step, and `list` and `stats` show what the server holds. `s.add` takes `cron:` (with `zone:`), `every:` (with `offset:`) or a raw `spec:`, the put options with their usual defaults and value shapes, and `catchup:`. See "Recurring Schedules" in the README.
* `sync` refuses an empty set unless given `allow_empty: true`. An empty sync removes every entry the owner has, and an app that loaded an empty config by mistake shouldn't wipe its schedule.
* `sync` runs on a short-lived connection of its own, closed afterwards. A worker blocked in `reserve` on the client's connection can't hold it up, and an error partway can't leave that connection mid-sync. If the socket drops, the whole sync is re-run from the start, never resumed partway.
* Add `Tuber::ScheduleSyncError` for a sync tuber refuses. It names the owner, the refused entry (`#entry`) and tuber's reply (`#status`). The gem aborts the sync before raising, so the previous schedule keeps running. `#applied?` is true for the one exception: a commit that took effect but couldn't be written to disk.
* `schedules.stats` returns a `StatStruct`, like tube and job stats: `stats.next_fire` or `stats["next-fire"]`. Times come back as `Time` in the entry's own zone, counters as Integers, and empty fields as nil.
* Add `Connection#transmit_raw`, which returns an `OK <bytes>` body unparsed. `transmit`'s YAML handling rewrites `:`, `-` and `~` inside values, and schedule stats are full of them.
* Fix a put refused with `OUT_OF_STORAGE` coming back as a result hash, as though it had succeeded. Tuber sends that reply once a persistent server's `--max-storage-bytes` budget is spent. It now raises the new `Tuber::OutOfStorageError`, as `OUT_OF_MEMORY` raises `OutOfMemoryError`.
* `Tuber::UnexpectedResponse.new` takes an optional message as a third argument.

## 0.6.0 (September 16 2026)

Reconnection release. The gem retried reconnects but not connects, so a
consumer that caught `Tuber::NotConnected` and built a new client — the obvious
thing to write — never reached the retrying path, and a server restart of a few
seconds was enough to kill it. `reconnect!` makes the existing healing
reachable, and `connect_retries` gives a cold start a window wider than the
outage. Existing behaviour is unchanged until `connect_retries` is raised, with
two exceptions noted below: `NotConnected` messages gained a suffix (the
historical text remains a strict prefix), and a connect error other than
`ECONNREFUSED` is now retried and surfaced as `NotConnected` rather than
escaping as a raw `Errno`.

* Add `Tuber#reconnect!` / `Connection#reconnect!`: re-establishes the connection and replays its tube state (watched tubes with their weights, the used tube, the reserve mode). This healing only ever ran when the connection itself noticed a dropped socket, so a consumer that caught `Tuber::NotConnected` had no way to reach it and had to build a new client — which starts with no tube state and has to re-watch and re-weight every tube by hand.
* Add `connect_retries` and `connect_retry_interval` configuration. The initial connect took exactly one attempt with no retry, so a cold start during a server restart — a web boot, a fresh `Tuber.new`, a daemon rebuilding its client after an error — failed where an established connection would have healed. Defaults to the historical single attempt; raising it also lifts the reconnect budget of connections already established, so one knob covers both.
* Retry a connect that fails for any reason the server might be unreachable (`ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, DNS failure, connect timeout), not only `ECONNREFUSED`. Those previously escaped as a raw `Errno` from the middle of a reconnect, a class no consumer thinks to rescue.
* `Tuber::NotConnected` now names the underlying error in its message and keeps it as the exception's `cause`. A bare `rescue` collapsed every connect failure into "Connection to beanstalk '...' is closed!", hiding whether the server refused, timed out, or was never resolved — exactly what you need during an outage.
* `Connection#close` no longer raises if the socket cannot be closed cleanly; the connection is gone either way and `reconnect!` must not fail on the way to replacing it.
* Fix a reconnect silently dropping per-tube weights and the connection's reserve mode ([#1](https://github.com/tuberq/tuber-gem/issues/1)). Both are per-connection server state that a fresh socket resets, so a consumer that healed across a brief server restart kept working but quietly fell back to FIFO. `Connection` now remembers the weight each tube was watched with and the mode set by `Tubes#reserve_mode`, and replays them (watch, then `ignore default`, then `reserve-mode`) when re-initialising tubes.
* Fix `_initialize_tubes` sending `ignore default` after a reconnect even when `default` was one of the watched tubes, which dropped it from the watch list.
* `Connection#add_to_watched` now takes an optional weight as a second argument, and `Connection#tube_weights` / `Connection#reserve_mode` expose the replayed state.

## 0.5.1 (August 13 2026)

* Fix empty keyword arguments forwarded through `Tube#transmit`, `Tubes#transmit` and `Jobs#transmit` arriving as an extra positional `{}` on Ruby 2.7
* CI: start the Tuber container with an explicit `server` subcommand, add Ruby 4.0 to the test matrix

## 0.5.0 (August 13 2026)

First functional release under the `tuber` name. Versioning restarts below 1.0
while the Tuber-first API settles; 1.0.0 will follow once it has. Entries below
1.1.4 with earlier version numbers are beaneater history.

* **Renamed from `beaneater` to `tuber`** (briefly `russet` while the gem name was being freed up, though never published under that name). The `Beaneater` class is now `Tuber`, and `require 'beaneater'` becomes `require 'tuber'`. Nothing else changed in the rename — see "Migrating from beaneater" in the README.
* Fix `_with_retry` retransmitting non-idempotent commands (`put`/`delete`/`release`/`bury`/`touch`/`kick` and batch variants) after a reconnect: the first send's fate is unknown, so a re-sent `put` could duplicate a job and a re-sent `delete` could raise `NOT_FOUND` for work that succeeded. These verbs now reconnect (and re-watch tubes) but re-raise the original connection error so the caller decides; idempotent commands keep the transparent retry.
* Add `Jobs#touch_all` (Tuber 0.12.0+): one-command heartbeat for every job the connection holds, returning how many were still held
* Add `Tube#flush_buried` (Tuber only): atomically deletes only the buried jobs in a tube, returning the count
* Add optional long-poll `timeout` to `reserve_batch` (Tuber only): `tubes.reserve_batch(count, timeout)` blocks up to `timeout` seconds for the first job, then drains what's ready
* Add `connect_timeout` (Ruby 3+), `resolv_timeout` (Ruby 3+), `read_timeout`, and `write_timeout` configuration options (@rveznaver)
* Fix fractional timeout handling for `read_timeout` and `write_timeout` socket options
* Add `TUBER_URL` environment variable and `config.tuber_url` as the primary way to point at a server; `BEANSTALKD_URL` and `config.beanstalkd_url` remain as compatible fallbacks/aliases
* Tests can target a specific server via `TUBER_TEST_ADDRESS`, and Tuber-only tests skip automatically against stock beanstalkd; CI runs the full suite against Tuber and the portable subset against beanstalkd
* Fix `StatStruct#[]` raising a `SyntaxError` when looking up hyphenated beanstalkd keys (e.g. `stats['current-jobs-ready']`); keys are now underscored before lookup to match how they are stored

## 1.1.4 (March 6 2026)

* Add frozen string literal comments for Ruby 3.4 compatibility (@nearapogee)
* Update tests for Ruby 3.4.x (@nearapogee)
* Add GitHub Actions CI workflow (@Ifiht)
* Update README.md (@Ifiht)

## 1.1.3 (Oct 14 2022)

* Fixes issue introduced in 1.1.2 re YML parsing (@pond)
* Fix job lookup test so it passes again

## 1.1.2 (Oct 10 2022)

* Fixes beaneater when used with Ruby 3.1 and YAML 4 (@pond)

## 1.1.1 (April 27th 2021)

* Support Ruby 3 keyword arguments (@yahonda)
* Add CI for Ruby 3 (@yahonda)

## 1.1.0 (April 25th 2021)

* 'clear' behavior was failing unexpectedly, swallow issues during delete as well (@bfolkens)
* Fix assigned but unused variables (@utilum)
* Fix last_used tube not stored (@albb0920)
* Fix deprecation warning in ruby 2.7 (@albb0920)
* Fix watched tubes not restored after reconnect (@albb0920)
* Fix keyword arguemnt warning (@albb0920)

## 1.0.0 (April 26th 2015)

* Beginning from version 1.0.0 the support for `Beaneater::Pool` has been dropped (@alup)
* `Jobs#find_all` method has been removed, since it is no longer necessary after removing pool (@alup)
* `Tubes` is now an enumerable allowing `tubes` to be handled as a collection (@Aethelflaed)

## 0.3.3 (August 16th 2014)

* Fix failure when job is not defined and fix exception handling for jobs (@nicholasorenrawlings)
* Add reserve_timeout option to job processing (@nicholasorenrawlings)
* Add travis-ci badge (@tdg5)
* Fix tests to run more reliably (@tdg5)

## 0.3.2 (Sept 15 2013)

* Fix #29 ExpectedCrlfError name and invocation (@tdg5)

## 0.3.1 (Jun 28 2013)

* Fixes issue with "chomp" nil exception when losing connection (Thanks @simao)
* Better handling of unknown or invalid commands during transmit
* Raise proper CRLF exception (Thanks @carlosmoutinho)

## 0.3.0 (Jan 23 2013)

* Replace Telnet with tcpsocket thanks @vidarh

## 0.2.2 (Dec 2 2012)

* Fixes status and ID parsing in a response (Thanks @justincase)

## 0.2.1 (Dec 1 2012)

* Convert command to ASCII_8Bit to avoid gsub issues

## 0.2.0 (Nov 12 2012)
* Fix 1.8.7 compatibility issues
* Add configuration block to beaneater and better job parsing
* BREAKING: json jobs now return as string by default not hashes

## 0.1.2 (Nov 7 2012)

* Add timeout: false to transmit to allow longer reserve

## 0.1.1 (Nov 4 2012)

* Add `Jobs#find_all` to fix #10
* Fixed issue with `tubes-list` by merging results
* Add `Job#ttr`, `Job#pri`, `Job#delay`
* Improved yardocs coverage and accuracy

## 0.1.0 (Nov 1 2012)

* Initial release!
