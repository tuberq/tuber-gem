# tuber

Ruby client for [Tuber](https://github.com/tuberq/tuber), a fast job queue server written in Rust. Tuber is wire-compatible with [beanstalkd](https://github.com/beanstalkd/beanstalkd) and extends it with unique jobs, concurrency control, job group pipelines, batch operations, weighted queues, and offloaded job bodies.

**This gem currently reserves the name while the client is finalized.** In the meantime, use [russet](https://github.com/dkam/russet) — a beaneater fork with full support for Tuber's protocol extensions — to talk to Tuber or beanstalkd from Ruby.

## Links

- Tuber server: https://github.com/tuberq/tuber
- Ruby client (current): https://github.com/dkam/russet

## License

MIT
