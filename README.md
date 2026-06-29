# PiiCipher

A Rails gem that enables **searchable blind indexing** for PII fields — powered by a Rust extension for performance.

PiiCipher handles the **search layer** of encrypted PII. It is designed to sit alongside Rails' built-in `ActiveRecord::Encryption` (`encrypts :email`), which handles the actual column encryption. Together they give you full GDPR-compliant storage: the real value never touches the database as plaintext, and searching still works.

PiiCipher computes HMAC-SHA256 hashes of the plaintext value before it is encrypted, and stores those hashes in a separate column. Queries are rewritten to search the hashes — the ciphertext column is never scanned.

Two search modes are supported:

| Mode | Column type | Use case |
|------|-------------|----------|
| **Partial** (default) | `jsonb` array | `LIKE`-style substring searches (e.g. searching `"smi"` matches `"Smith"`) |
| **Exact** | `string` | Exact-match lookups (e.g. looking up a full SSN or email) |

## How it works

### Partial search — trigram blind indexing

For partial search, PiiCipher slides a 3-character window across the plaintext and HMAC-SHA256s each trigram using your secret key:

```
"Smith" → ["Smi", "mit", "ith"] → [hmac("Smi"), hmac("mit"), hmac("ith")]
```

These hashes are stored in a `jsonb` array column. Querying with `where(email: "mit")` generates the same hashes for the search term and uses a PostgreSQL `@>` (contains) check — no plaintext ever touches the database.

### Exact search — single blind index

For exact match, a single HMAC-SHA256 of the full value is stored in a regular string column. Querying generates the same hash and does a standard equality check.

Both hash functions live in a Rust extension (`magnus` + `hmac-sha256`) and are called transparently from Ruby.

### Column encryption (the full picture)

PiiCipher only generates the blind indexes — it does not encrypt the column itself. Column encryption is handled by Rails AR Encryption (`encrypts`). The two work at different layers and do not interfere:

```
user.save
 ├─ before_save (pii_cipher) → reads plaintext → writes hashes to email_bidx_array
 └─ DB write (Rails AR Enc.) → encrypts plaintext → writes ciphertext to email column
```

Because Rails AR Encryption works at the DB serialization layer (not a callback), `self.email` always returns plaintext during `before_save` — pii_cipher always hashes the real value, never the ciphertext.

## Requirements

- Ruby >= 4.0.4
- Rails >= 8.1
- PostgreSQL
- Rust toolchain (only needed when building the gem from source)

## Installation

Add to your `Gemfile`:

```ruby
gem "pii_cipher"
```

Then run:

```bash
bundle install
```

## Setup

### 1. Generate Rails AR Encryption keys

Run this once to generate the three keys Rails AR Encryption needs:

```bash
bin/rails db:encryption:init
```

Copy the output into your credentials file:

```bash
bin/rails credentials:edit
```

```yaml
active_record_encryption:
  primary_key: <generated>
  deterministic_key: <generated>
  key_derivation_salt: <generated>
```

These keys encrypt and decrypt the column values. Keep them in your secrets manager — losing them means losing access to your data.

### 2. Set the PiiCipher secret key

PiiCipher reads the HMAC key from the `PII_SECRET_KEY` environment variable. Add it to your environment (e.g. via credentials, dotenv, or your secrets manager):

```bash
PII_SECRET_KEY=your-long-random-secret-here
```

Generate a secure random value with:

```bash
rails secret
```

Changing this key will invalidate all existing blind indexes.

### 3. Add blind index columns

For each encrypted attribute, add the corresponding blind index column in a migration.

**Partial search** (default — stores trigram hashes in a `jsonb` array):

```ruby
class AddEmailBidxToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :email_bidx_array, :jsonb
    add_index  :users, :email_bidx_array, using: :gin
  end
end
```

**Exact search** (stores a single hash string):

```ruby
class AddSsnBidxToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :ssn_bidx, :string
    add_index  :users, :ssn_bidx
  end
end
```

The GIN index on `jsonb` columns is strongly recommended for performance on partial searches.

### 4. Declare encrypted attributes in your model

Declare `encrypts` (Rails AR Encryption) first, then `use_pii_cipher`. Both must be present for full GDPR-compliant searchable encryption.

```ruby
class User < ApplicationRecord
  encrypts :email                      # Rails: stores ciphertext in DB, decrypts on read
  use_pii_cipher :email                # pii_cipher: generates trigram blind indexes from plaintext

  encrypts :ssn
  use_pii_cipher :ssn, partial: false  # exact-match blind index
end
```

Multiple attributes can be passed to `use_pii_cipher` in a single call:

```ruby
encrypts :email, :phone_number
use_pii_cipher :email, :phone_number
```

## Usage

### Saving records

No changes to your existing create/update code. Everything happens automatically:

```ruby
User.create!(email: "alice@example.com", ssn: "123-45-6789")
```

What happens under the hood:

1. `before_save` (pii_cipher) reads `"alice@example.com"` as plaintext, generates trigram hashes, writes them to `email_bidx_array`
2. Rails AR Encryption encrypts `"alice@example.com"` and writes ciphertext to the `email` column

### What's in the database vs what Ruby sees

```ruby
user = User.find(1)

# Ruby — always decrypted transparently by Rails
user.email
# => "alice@example.com"

# Raw database row — email column holds ciphertext, blind index holds hashes
# email         => {"p":"Wd5LybiwJGPHYI...","h":{"iv":"XJul...","at":"Pk..."}}
# email_bidx_array => ["a3f2c1...", "9b4e7d...", ...]
```

Nobody with direct database access can read the email. The blind index is just opaque hashes — it reveals nothing about the original value without the `PII_SECRET_KEY`.

### Querying

Pass the plaintext value to `where` exactly as you normally would — PiiCipher intercepts encrypted columns and rewrites the query to search the blind index:

```ruby
# Partial search — finds any user whose email contains "alice"
User.where(email: "alice")

# Exact search — finds the user with that exact SSN
User.where(ssn: "123-45-6789")

# Mix encrypted and plain columns freely
User.where(email: "alice", status: "active")
```

The found records have their emails decrypted by Rails on the way out — callers always receive plaintext. The interceptor only rewrites keys declared with `use_pii_cipher`; all other `where` calls pass through to ActiveRecord unchanged.

## Performance

Benchmarked on a local machine against PostgreSQL 18 with 100,000 rows. The comparison baseline is a plain (unencrypted) column with a standard index — the closest real-world alternative for each search type.

### Writes

| | Time (100k rows) |
|---|---|
| Plain insert | 1,221 ms |
| Encrypted insert | 2,861 ms (+134%) |

The overhead is not from the Rust hashing — that runs in microseconds. It comes from **writing significantly more data per row**: each record gains a `jsonb` array of 64-character HMAC hex strings (one per trigram) and a 64-character blind index string. Both the larger rows and the GIN index maintenance during insert contribute to the slower writes.

### Reads

| Query type | Plain | Encrypted | Difference |
|---|---|---|---|
| Exact match (B-tree) | 0.121 ms | 0.095 ms | ~within noise |
| Partial match (GIN) | 1.515 ms | 1.865 ms | +23% |

**Exact match** is effectively identical. Both paths hit a B-tree index; the lookup cost is the same regardless of what the key looks like.

**Partial match** is ~23% slower. The GIN index sizes end up comparable (see below), but PostgreSQL has to parse the `jsonb` array and evaluate the `@>` containment operator on each probe, which adds a small constant overhead that `pg_trgm`'s native GIN operator doesn't pay.

### Storage

| | Table total | Email index | Name GIN index |
|---|---|---|---|
| Plain | 21 MB | 5 MB | 7.2 MB |
| Encrypted | 89 MB | 12 MB | 7.0 MB |

The table is **4.2× larger**. Every stored trigram hash is 64 characters regardless of what the original value looked like — a 5-character name still produces 3 trigrams × 64 chars = 192 bytes of blind index data. At large scale, this is the dominant cost to plan for.

The email B-tree index is 2.4× larger for the same reason (64-char hash vs ~25-char email). The name GIN index sizes are nearly identical — HMAC hashes repeat across rows the same way plain trigrams do (same input + same key = same hash), so the GIN posting lists compress similarly.

### What this means in practice

- **Reads are fast.** Sub-millisecond exact lookups and ~2ms partial searches hold up well even at this row count.
- **Writes cost more.** If your workload is write-heavy on PII fields, budget for the extra insert time.
- **Storage is the main tradeoff.** Plan for roughly 4× the table and index footprint compared to an equivalent unencrypted schema.

You can reproduce these results yourself:

```bash
ruby -I lib benchmarks/run.rb
```

## Configuration reference

`use_pii_cipher(*attributes, partial: true)`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `partial` | Boolean | `true` | `true` → trigram array in `column_bidx_array`; `false` → single hash in `column_bidx` |

## Development

After checking out the repo, run `bin/setup` to install dependencies (this also compiles the Rust extension). Then run the test suite:

```bash
bundle exec rake spec
```

To open an interactive console with the gem loaded:

```bash
bin/console
```

To build and install the gem locally:

```bash
bundle exec rake install
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/selvachezhian/pii_cipher. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
