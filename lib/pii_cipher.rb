# frozen_string_literal: true

# lib/pii_cipher.rb
require_relative "pii_cipher/version"

# 1. Load the compiled Rust extension. It defines:
#      PiiCipher.generate_ngram_hashes(text, secret, n) -> [hash, ...]
#      PiiCipher.generate_blind_index(text, secret)     -> hash
#
# Precompiled (native) gems ship the binary in a per-Ruby-ABI subdirectory
# (lib/pii_cipher/3.3/pii_cipher.bundle) so one gem can serve several Ruby
# versions. Source builds compile straight into lib/pii_cipher/pii_cipher.*.
# Try the version-specific path first, then fall back to the flat one.
begin
  require_relative "pii_cipher/#{RUBY_VERSION[/\d+\.\d+/]}/pii_cipher"
rescue LoadError
  require_relative "pii_cipher/pii_cipher"
end

# 2. Load our Ruby logic
require_relative "pii_cipher/active_record_ext"
require_relative "pii_cipher/query_interceptor"

module PiiCipher
  # Raised when the HMAC secret key is not configured.
  class MissingSecretKeyError < StandardError; end

  class << self
    # The HMAC secret used for all blind indexes. Read from the
    # `PII_SECRET_KEY` environment variable. Changing it invalidates every
    # existing blind index.
    def secret_key
      ENV.fetch("PII_SECRET_KEY") do
        raise MissingSecretKeyError,
              "PII_SECRET_KEY is not set. PiiCipher needs it to generate blind indexes."
      end
    end

    # Apply the per-attribute normalization (currently just case-folding) that
    # must be identical on writes and queries.
    def normalize(value, config)
      str = value.to_s
      config[:case_sensitive] ? str : str.downcase
    end

    # Idempotently prepend the query patch onto ActiveRecord::Relation. Called
    # the first time any model declares `use_pii_cipher`, by which point
    # ActiveRecord is guaranteed to be loaded. Guarded so it only happens once.
    def install_query_patch!
      return if @query_patch_installed
      return unless defined?(ActiveRecord::Relation)

      ActiveRecord::Relation.prepend(PiiCipher::RelationExt)
      @query_patch_installed = true
    end
  end
end

# 3. Load the Railtie ONLY if Rails is present in the user's app
require_relative "pii_cipher/railtie" if defined?(Rails)
