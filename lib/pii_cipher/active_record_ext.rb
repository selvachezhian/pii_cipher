# lib/pii_cipher/active_record_ext.rb
require 'active_support/concern'

module PiiCipher
  module ActiveRecordExt
    extend ActiveSupport::Concern

    class_methods do
      # 1. Changed the default keyword argument to partial: true
      def use_pii_cipher(*attributes, partial: true)

        # Setup a registry to remember which columns are encrypted.
        # Using ||= ensures we add to the hash rather than wiping it out 
        # if the developer calls this method multiple times.
        class_attribute :pii_cipher_configs unless defined?(pii_cipher_configs)
        self.pii_cipher_configs ||= {}

        # Save the configuration for each passed attribute
        attributes.each do |attr|
          self.pii_cipher_configs[attr.to_sym] = { partial: partial }
        end

        # 2. Safeguard to ensure we only inject the callbacks once per model,
        # even if `use_pii_cipher` is called multiple times.
        unless defined?(@_pii_cipher_configured) && @_pii_cipher_configured
          before_save :generate_pii_ciphers!

          class << self
            prepend PiiCipher::QueryInterceptor
          end

          @_pii_cipher_configured = true
        end
      end
    end

    private

    # This method runs automatically before `record.save`
    def generate_pii_ciphers!
      secret = ENV.fetch('PII_SECRET_KEY')

      self.class.pii_cipher_configs.each do |column, config|
        raw_value = self.send(column)

        # Skip if the user didn't provide a value for this column
        next if raw_value.blank?

        if config[:partial]
          # DEFAULT BEHAVIOR: Use Rust to generate trigram hashes for LIKE searches
          hashes = PiiCipher.generate_trigram_hashes(raw_value.to_s, secret)
          self.send("#{column}_bidx_array=", hashes)
        else
          # OPT-OUT BEHAVIOR: Use Rust to generate a single hash for EXACT searches
          hash = PiiCipher.generate_blind_index(raw_value.to_s, secret)
          self.send("#{column}_bidx=", hash)
        end
      end
    end
  end
end
