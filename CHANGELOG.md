## [Unreleased]

## [0.1.1] - 2026-06-29

- Fix precompiled-gem loading: `lib/pii_cipher.rb` now resolves the native binary
  from its per-Ruby-ABI subdirectory (`lib/pii_cipher/<ver>/`), falling back to the
  flat path for source builds. v0.1.0 precompiled gems failed to load with a
  `LoadError` because no version-aware require existed.
- Widen precompiled coverage to every platform and stable Ruby version the rb-sys
  toolchain supports (now including Ruby 3.4 and 4.0 and the linux-musl/Alpine
  targets), so installing on the latest Ruby no longer falls back to a source build.

## Pre-0.1.1 unreleased changes

- Case-insensitive search by default (values are downcased before hashing); opt out with `case_sensitive: true`.
- Configurable partial-search window via `gram_size:` (default 3).
- Query rewriting now works on chained relations and scopes, not just direct `Model.where` calls.
- `where` no longer mutates the conditions hash passed to it.
- Blanking an attribute now clears its blind index instead of leaving a stale one.
- Clearer error (`PiiCipher::MissingSecretKeyError`) when `PII_SECRET_KEY` is unset.
- Lowered requirements to Ruby >= 3.1 and ActiveRecord/Railties >= 7.1.
- Replaced placeholder test with a real RSpec suite (unit + PostgreSQL integration) and Rust unit tests; CI now runs across Ruby 3.1–4.0 with a Postgres service.
- Renamed the Rust entry point `generate_trigram_hashes` → `generate_ngram_hashes(text, secret, n)`.

## [0.1.0] - 2026-05-16

- Initial release
