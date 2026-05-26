# frozen_string_literal: true

require_relative "lib/pii_cipher/version"

Gem::Specification.new do |spec|
  spec.name = "pii_cipher"
  spec.version = PiiCipher::VERSION
  spec.authors = ["Selva Chezhian"]
  spec.email = ["selvachezhian.labam@gmail.com"]

  spec.summary = "Searchable blind indexing for PII fields in Rails, powered by a Rust extension."
  spec.description = <<~DESC
    PiiCipher lets you search encrypted PII columns in ActiveRecord without ever
    storing or querying plaintext. It generates HMAC-SHA256 blind indexes alongside
    your ciphertext — trigram arrays for partial (substring) searches and single
    hashes for exact-match lookups. The hash functions run in a native Rust
    extension for performance. Query interception is transparent: call `where`
    as normal and PiiCipher rewrites the query against the blind index automatically.
  DESC
  spec.homepage = "https://github.com/[USERNAME]/pii_cipher"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.4"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/[USERNAME]/pii_cipher"
  spec.metadata["changelog_uri"] = "https://github.com/[USERNAME]/pii_cipher/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/pii_cipher/extconf.rb"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"
  spec.add_dependency "rb_sys", "~> 0.9.91"
  spec.add_dependency "activerecord", ">= 8.1"
  spec.add_dependency "railties", ">= 8.1"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
