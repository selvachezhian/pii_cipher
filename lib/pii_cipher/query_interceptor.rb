# lib/pii_cipher/query_interceptor.rb

module PiiCipher
  module QueryInterceptor
    # We override the standard ActiveRecord `where` method
    def where(*args)
      opts = args.first

      # We only want to intercept if the developer passed a Hash (e.g., where(email: 'smith'))
      if opts.is_a?(Hash)
        # Find which keys in the query belong to our encrypted columns
        encrypted_keys = opts.keys.select { |k| pii_cipher_configs.key?(k.to_sym) }

        if encrypted_keys.any?
          # Start a new relation chain
          relation = self
          secret = ENV.fetch('PII_SECRET_KEY')

          encrypted_keys.each do |key|
            # Remove the encrypted key from the standard query options
            raw_search_term = opts.delete(key)
            config = pii_cipher_configs[key.to_sym]

            # Rewrite the query based on partial vs exact matching
            if config[:partial]
              hashes = PiiCipher.generate_trigram_hashes(raw_search_term.to_s, secret)
              relation = relation.where("#{key}_bidx_array @> ?::jsonb", hashes.to_json)
            else
              hash = PiiCipher.generate_blind_index(raw_search_term.to_s, secret)
              relation = relation.where("#{key}_bidx" => hash)
            end
          end

          # If there are still standard columns left in the hash (like `name: 'xxx'`), chain them!
          return relation.where(opts) if opts.any?

          # Otherwise, return the modified relation chain
          return relation
        end
      end

      # If there are no encrypted keys, or they used string queries (where("id > 1")),
      # fall back to standard ActiveRecord behavior
      super
    end
  end
end
