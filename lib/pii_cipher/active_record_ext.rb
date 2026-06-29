# frozen_string_literal: true

# lib/pii_cipher/active_record_ext.rb
require "active_support/concern"

module PiiCipher
  # Default sliding-window size for partial (n-gram) blind indexes.
  DEFAULT_GRAM_SIZE = 3

  module ActiveRecordExt
    extend ActiveSupport::Concern

    class_methods do
      # Declare one or more attributes as searchable encrypted PII.
      #
      #   use_pii_cipher :email                       # partial trigram search
      #   use_pii_cipher :ssn, partial: false         # exact-match search
      #   use_pii_cipher :name, gram_size: 4          # 4-gram partial search
      #   use_pii_cipher :email, case_sensitive: true # do not downcase
      #
      # Options:
      #   partial:        true  -> trigram/n-gram array in `<attr>_bidx_array`
      #                   false -> single hash in `<attr>_bidx`
      #   gram_size:      window size for partial search (default: 3). Ignored
      #                   when partial: false.
      #   case_sensitive: false (default) downcases values before hashing so
      #                   searches are case-insensitive. Must match between the
      #                   stored index and queries — changing it invalidates
      #                   existing indexes.
      def use_pii_cipher(*attributes, partial: true, gram_size: PiiCipher::DEFAULT_GRAM_SIZE,
                         case_sensitive: false)
        if partial && (!gram_size.is_a?(Integer) || gram_size < 1)
          raise ArgumentError, "gram_size must be a positive integer (got #{gram_size.inspect})"
        end

        # Registry of which attributes are indexed and how. Built with merge so
        # repeated calls accumulate, and so subclasses (STI) get their own copy
        # rather than mutating a parent's shared hash.
        class_attribute :pii_cipher_configs unless respond_to?(:pii_cipher_configs)
        self.pii_cipher_configs ||= {}

        new_configs = attributes.each_with_object({}) do |attr, acc|
          acc[attr.to_sym] = {
            partial: partial,
            gram_size: gram_size,
            case_sensitive: case_sensitive
          }
        end
        self.pii_cipher_configs = pii_cipher_configs.merge(new_configs)

        # Install callbacks and the query patch once per model.
        unless defined?(@_pii_cipher_configured) && @_pii_cipher_configured
          before_save :generate_pii_ciphers!
          PiiCipher.install_query_patch!
          @_pii_cipher_configured = true
        end
      end
    end

    private

    # Runs automatically before `record.save`. Reads the still-plaintext value
    # (Rails AR Encryption serializes at the DB layer, not via callbacks) and
    # writes the blind index(es).
    def generate_pii_ciphers!
      secret = PiiCipher.secret_key

      self.class.pii_cipher_configs.each do |column, config|
        raw_value = send(column)

        if raw_value.blank?
          # Clear any stale index so a removed/blanked value stops matching.
          if config[:partial]
            send("#{column}_bidx_array=", nil)
          else
            send("#{column}_bidx=", nil)
          end
          next
        end

        value = PiiCipher.normalize(raw_value, config)

        if config[:partial]
          hashes = PiiCipher.generate_ngram_hashes(value, secret, config[:gram_size])
          send("#{column}_bidx_array=", hashes)
        else
          send("#{column}_bidx=", PiiCipher.generate_blind_index(value, secret))
        end
      end
    end
  end
end
