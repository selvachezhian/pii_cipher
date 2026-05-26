# lib/pii_cipher/railtie.rb
require 'rails/railtie'

module PiiCipher
  class Railtie < Rails::Railtie
    initializer 'pii_cipher.initialize' do
      ActiveSupport.on_load(:active_record) do
        # Injects our macro into ApplicationRecord automatically!
        include PiiCipher::ActiveRecordExt
      end
    end
  end
end
