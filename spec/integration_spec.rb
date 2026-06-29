# frozen_string_literal: true

#
# End-to-end integration against a real PostgreSQL database, since PiiCipher's
# partial search relies on the jsonb `@>` containment operator. These specs
# build a plain table (no AR Encryption needed — PiiCipher operates purely on
# the blind-index columns) and exercise saving and querying.
#
# Connection is configured via standard PG* env vars, falling back to a local
# default. CI provides a postgres service; see .github/workflows/main.yml.

require "active_record"

RSpec.describe "PiiCipher integration", :integration do
  before(:all) do
    ActiveRecord::Base.establish_connection(
      adapter: "postgresql",
      host: ENV.fetch("PGHOST", "localhost"),
      port: ENV.fetch("PGPORT", 5432),
      username: ENV.fetch("PGUSER", "postgres"),
      password: ENV.fetch("PGPASSWORD", "postgres"),
      database: ENV.fetch("PGDATABASE", "pii_cipher_test")
    )

    # Make `use_pii_cipher` available (the Railtie does this automatically in a
    # Rails app; here we wire it up by hand).
    ActiveRecord::Base.include(PiiCipher::ActiveRecordExt)

    conn = ActiveRecord::Base.connection
    conn.create_table :people, force: true do |t|
      t.string  :email
      t.string  :ssn
      t.string  :nickname
      t.boolean :active, default: true
      t.jsonb   :email_bidx_array
      t.string  :ssn_bidx
      t.jsonb   :nickname_bidx_array
    end
  end

  after(:all) do
    ActiveRecord::Base.connection.drop_table :people, if_exists: true
    ActiveRecord::Base.remove_connection
  end

  before(:each) do
    Object.send(:remove_const, :Person) if defined?(Person)
    person_class = Class.new(ActiveRecord::Base) do
      self.table_name = "people"
      use_pii_cipher :email                     # partial, trigram, case-insensitive
      use_pii_cipher :ssn, partial: false       # exact
      use_pii_cipher :nickname, gram_size: 4    # partial, 4-gram
    end
    Object.const_set(:Person, person_class)
    Person.delete_all
  end

  describe "writing blind indexes" do
    it "stores downcased trigram hashes for partial attributes" do
      p = Person.create!(email: "Alice@Example.com")
      expected = PiiCipher.generate_ngram_hashes("alice@example.com",
                                                 PiiCipher.secret_key, 3)
      expect(p.email_bidx_array).to eq(expected)
    end

    it "stores a single hash for exact attributes" do
      p = Person.create!(ssn: "123-45-6789")
      expect(p.ssn_bidx).to eq(
        PiiCipher.generate_blind_index("123-45-6789", PiiCipher.secret_key)
      )
    end

    it "clears the index when the value is blanked" do
      p = Person.create!(email: "alice@example.com")
      expect(p.email_bidx_array).not_to be_nil
      p.update!(email: "")
      expect(p.reload.email_bidx_array).to be_nil
      expect(Person.where(email: "alice")).to be_empty
    end
  end

  describe "querying" do
    before do
      @alice = Person.create!(email: "Alice@Example.com", ssn: "111-11-1111",
                              nickname: "Allie", active: true)
      @bob   = Person.create!(email: "bob@work.org", ssn: "222-22-2222",
                              nickname: "Bobby", active: false)
    end

    it "finds records by exact full value (case-insensitive)" do
      expect(Person.where(email: "alice@example.com")).to contain_exactly(@alice)
    end

    it "matches regardless of the case used in the query or stored value" do
      expect(Person.where(email: "ALICE@EXAMPLE.COM")).to contain_exactly(@alice)
    end

    it "finds records by substring (partial search)" do
      expect(Person.where(email: "lice")).to contain_exactly(@alice)
    end

    it "does an exact lookup for non-partial attributes" do
      expect(Person.where(ssn: "222-22-2222")).to contain_exactly(@bob)
      expect(Person.where(ssn: "000-00-0000")).to be_empty
    end

    it "works on a chained relation, not just the class" do
      expect(Person.where(active: true).where(email: "alice")).to contain_exactly(@alice)
    end

    it "mixes encrypted and plain columns in one call" do
      expect(Person.where(email: "alice", active: true)).to contain_exactly(@alice)
      expect(Person.where(email: "alice", active: false)).to be_empty
    end

    it "uses the configured gram_size for that attribute" do
      # 4-gram column; "llie" is a 4-char substring of "Allie".
      expect(Person.where(nickname: "llie")).to contain_exactly(@alice)
    end

    it "does not mutate the caller's conditions hash" do
      conditions = { email: "alice", active: true }
      Person.where(conditions).to_a
      expect(conditions).to eq(email: "alice", active: true)
    end

    it "leaves non-PiiCipher queries untouched" do
      expect(Person.where(active: false)).to contain_exactly(@bob)
    end
  end
end
