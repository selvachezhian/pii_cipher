# frozen_string_literal: true

# lib/pii_cipher/query_interceptor.rb

module PiiCipher
  # Prepended onto ActiveRecord::Relation so that `where(hash)` is rewritten to
  # search blind indexes — for the model class itself AND for any relation
  # derived from it. Because `Model.where(...)` delegates to `Model.all.where`,
  # patching the relation also covers class-level calls, scopes, and chains
  # like `Model.active.where(email: "alice")`.
  #
  # Only hash-form `where` on attributes declared with `use_pii_cipher` is
  # rewritten. String/array conditions, and models that don't use PiiCipher,
  # pass straight through to ActiveRecord untouched.
  module RelationExt
    def where(*args, &block)
      opts = args.first

      configs = pii_cipher_configs_for_relation
      if configs && opts.is_a?(Hash)
        encrypted_keys = opts.keys.select { |k| configs.key?(k.to_sym) }

        if encrypted_keys.any?
          secret = PiiCipher.secret_key
          # Dup so we never mutate the caller's hash (e.g. `where(params)`).
          remaining = opts.dup
          relation = self

          encrypted_keys.each do |key|
            raw_term = remaining.delete(key)
            config = configs[key.to_sym]

            # nil means "search for records with no value" — match the cleared
            # (NULL) blind index rather than hashing nil.
            if raw_term.nil?
              column = config[:partial] ? "#{key}_bidx_array" : "#{key}_bidx"
              relation = relation.where(column => nil)
              next
            end

            value = PiiCipher.normalize(raw_term, config)

            relation =
              if config[:partial]
                hashes = PiiCipher.generate_ngram_hashes(value, secret, config[:gram_size])
                relation.where("#{key}_bidx_array @> ?::jsonb", hashes.to_json)
              else
                relation.where("#{key}_bidx" => PiiCipher.generate_blind_index(value, secret))
              end
          end

          # Chain any remaining standard columns (e.g. status: "active").
          relation = relation.where(remaining) if remaining.any?
          return relation
        end
      end

      super
    end

    private

    # The PiiCipher config for this relation's model, or nil if it doesn't use
    # PiiCipher. Guarded so prepending to the shared Relation class is a no-op
    # for every other model.
    def pii_cipher_configs_for_relation
      k = klass
      return nil unless k.respond_to?(:pii_cipher_configs)

      k.pii_cipher_configs
    end
  end
end
