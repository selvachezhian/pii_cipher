# lib/pii_cipher.rb
require_relative "pii_cipher/version"

# 1. Load the compiled Rust code (Notice we use pii_cipher here, not fast_crypto)
require_relative "pii_cipher/pii_cipher"

# 2. Load our Ruby logic
require_relative "pii_cipher/active_record_ext"
require_relative "pii_cipher/query_interceptor"

# 3. Load the Railtie ONLY if Rails is present in the user's app
require_relative "pii_cipher/railtie" if defined?(Rails)
