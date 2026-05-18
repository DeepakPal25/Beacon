# Changelog

Changes are documented here. Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-05-18

Initial release. Everything described in the README is in this version:

- `AnalyticsClient` - the main entry point, with `track`, `identify`, and `reset`
- Fan-out to multiple `AnalyticsProvider`s; each gets its own persistent queue and batch settings
- Consent layer with in-memory buffering, per-category routing, and purge on withdrawal
- JSON Lines persistence per provider, exponential backoff, and poison-pill handling for permanently bad batches
- Built-in processors: `PropertyEnricher`, `PIIRedactor`, `EventFilter`, `ClosureProcessor`
- Automatic session IDs with an inactivity timeout
- `HTTPBatchProvider` and `ConsoleProvider` included
- `BeaconTesting` module with `RecordingProvider` and `TestClock` for unit tests
