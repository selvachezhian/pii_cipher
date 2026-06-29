# frozen_string_literal: true

# A deterministic key for the test suite. Real apps read this from their
# secrets manager; here we just need it set before PiiCipher is exercised.
ENV["PII_SECRET_KEY"] ||= "test-secret-key-not-for-production"

require "pii_cipher"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # The integration suite needs a PostgreSQL database. Run it when PGHOST is set
  # (CI sets it); otherwise skip so a plain `rake` stays green locally.
  config.filter_run_excluding(:integration) unless ENV["PGHOST"]
end
