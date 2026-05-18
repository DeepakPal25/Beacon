# Contributing to Beacon

Thanks for taking a look — contributions are welcome.

## Getting started

```bash
git clone https://github.com/YOUR_USERNAME/Beacon.git
cd Beacon
swift test
```

You'll need Xcode 16 or later (Swift 6 strict concurrency is on).

## Before you write code

For anything bigger than a small bug fix, open an issue first. It's a lot easier to agree on an approach before the code exists than after.

## A few things to keep in mind

- Keep Beacon dependency-free. Vendor adapters belong in apps, not here.
- New code should compile cleanly under Swift 6 strict concurrency. Mutable state belongs in the `Pipeline` actor.
- New behaviour needs tests — use `RecordingProvider` and `TestClock`. Don't sleep in tests; inject a clock instead.
- Public API gets DocC comments.
- Add a line to `CHANGELOG.md` under *Unreleased*.

## Submitting

1. Fork and create a branch off `main`.
2. Make your change with tests.
3. Run `swift test` and make sure everything passes.
4. Open a PR with a short description of what changed and why.

By contributing, you agree your work will be licensed under MIT.
