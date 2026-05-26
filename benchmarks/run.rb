require 'active_record'
require 'benchmark'
require 'pg'

$LOAD_PATH.unshift File.join(__dir__, '..', 'lib')
require 'pii_cipher'

DB      = 'pii_cipher_benchmark'
SECRET  = 'benchmark-secret-key-do-not-use-in-prod'
ROWS    = 100_000
QUERIES = 1_000

NAMES = %w[
  Smith Johnson Williams Brown Jones Garcia Miller Davis Wilson Moore
  Taylor Anderson Thomas Jackson White Harris Martin Thompson Chezhian
  Robinson Clark Rodriguez Lewis Lee Walker Hall Allen Young Hernandez
].freeze

DOMAINS = %w[gmail.com yahoo.com outlook.com protonmail.com icloud.com].freeze

def rand_name  = "#{NAMES.sample}#{rand(9999)}"
def rand_email = "#{NAMES.sample.downcase}#{rand(9999)}@#{DOMAINS.sample}"

# ── DB setup ─────────────────────────────────────────────────────────────────

def connect(db = 'postgres')
  ActiveRecord::Base.establish_connection(adapter: 'postgresql', database: db, host: 'localhost')
  ActiveRecord::Base.connection
end

puts "==> Setting up database '#{DB}'..."
conn = connect('postgres')
conn.execute("DROP DATABASE IF EXISTS #{DB}")
conn.execute("CREATE DATABASE #{DB}")

conn = connect(DB)
conn.execute('CREATE EXTENSION IF NOT EXISTS pg_trgm')

conn.create_table :plain_users, force: true do |t|
  t.string :name,  null: false
  t.string :email, null: false
end

conn.create_table :encrypted_users, force: true do |t|
  t.string  :name,             null: false
  t.string  :email,            null: false
  t.jsonb   :name_bidx_array
  t.string  :email_bidx
end

# Indexes on plain table
conn.execute('CREATE INDEX idx_plain_email ON plain_users (email)')
conn.execute('CREATE INDEX idx_plain_name_trgm ON plain_users USING GIN (name gin_trgm_ops)')

# Indexes on encrypted table
conn.execute('CREATE INDEX idx_enc_email_bidx ON encrypted_users (email_bidx)')
conn.execute('CREATE INDEX idx_enc_name_bidx_array ON encrypted_users USING GIN (name_bidx_array)')

puts "==> Tables and indexes created.\n\n"

# ── Seed data (pre-generate so Rust/hash time isn't mixed with AR overhead) ──

puts "==> Pre-generating #{ROWS} rows of test data..."
plain_rows     = ROWS.times.map { { name: rand_name, email: rand_email } }
encrypted_rows = plain_rows.map do |r|
  {
    name:            r[:name],
    email:           r[:email],
    name_bidx_array: PiiCipher.generate_trigram_hashes(r[:name], SECRET).to_json,
    email_bidx:      PiiCipher.generate_blind_index(r[:email], SECRET)
  }
end
puts "==> Done.\n\n"

# ── Benchmark writes ──────────────────────────────────────────────────────────

puts "=" * 60
puts "WRITE BENCHMARK  (#{ROWS} rows, batch insert)"
puts "=" * 60

write_results = Benchmark.bm(30) do |x|
  x.report("Plain insert:") do
    plain_rows.each_slice(1000) do |batch|
      conn.execute(
        "INSERT INTO plain_users (name, email) VALUES " +
        batch.map { |r| "('#{conn.quote_string(r[:name])}','#{conn.quote_string(r[:email])}')" }.join(',')
      )
    end
  end

  x.report("Encrypted insert:") do
    encrypted_rows.each_slice(1000) do |batch|
      conn.execute(
        "INSERT INTO encrypted_users (name, email, name_bidx_array, email_bidx) VALUES " +
        batch.map { |r|
          name_array = r[:name_bidx_array].gsub("'", "''")
          "('#{conn.quote_string(r[:name])}','#{conn.quote_string(r[:email])}'," \
          "'#{name_array}'::jsonb,'#{conn.quote_string(r[:email_bidx])}')"
        }.join(',')
      )
    end
  end
end

plain_write_ms = (write_results[0].real * 1000).round(1)
enc_write_ms   = (write_results[1].real * 1000).round(1)
write_overhead = ((enc_write_ms - plain_write_ms) / plain_write_ms * 100).round(1)

# ── Benchmark reads ───────────────────────────────────────────────────────────

# Pick real values that exist in the DB for fair comparison
sample_plain_row     = conn.execute('SELECT name, email FROM plain_users ORDER BY RANDOM() LIMIT 1').first
exact_email          = sample_plain_row['email']
partial_name_term    = sample_plain_row['name'][0, 4]  # 4-char prefix

exact_email_bidx     = PiiCipher.generate_blind_index(exact_email, SECRET)
partial_hashes_json  = PiiCipher.generate_trigram_hashes(partial_name_term, SECRET).to_json

puts "\n"
puts "=" * 60
puts "READ BENCHMARK  (#{QUERIES} queries each)"
puts "  Exact search term : #{exact_email}"
puts "  Partial search term: #{partial_name_term}"
puts "=" * 60

read_results = Benchmark.bm(30) do |x|
  x.report("Plain exact (B-tree):") do
    QUERIES.times { conn.execute("SELECT id FROM plain_users WHERE email = '#{conn.quote_string(exact_email)}'") }
  end

  x.report("Encrypted exact (blind idx):") do
    QUERIES.times { conn.execute("SELECT id FROM encrypted_users WHERE email_bidx = '#{conn.quote_string(exact_email_bidx)}'") }
  end

  x.report("Plain partial (pg_trgm GIN):") do
    QUERIES.times { conn.execute("SELECT id FROM plain_users WHERE name LIKE '%#{conn.quote_string(partial_name_term)}%'") }
  end

  x.report("Encrypted partial (bidx GIN):") do
    QUERIES.times { conn.execute("SELECT id FROM encrypted_users WHERE name_bidx_array @> '#{partial_hashes_json}'::jsonb") }
  end
end

plain_exact_ms   = (read_results[0].real * 1000 / QUERIES).round(3)
enc_exact_ms     = (read_results[1].real * 1000 / QUERIES).round(3)
plain_partial_ms = (read_results[2].real * 1000 / QUERIES).round(3)
enc_partial_ms   = (read_results[3].real * 1000 / QUERIES).round(3)

exact_overhead   = ((enc_exact_ms   - plain_exact_ms)   / plain_exact_ms   * 100).round(1)
partial_overhead = ((enc_partial_ms - plain_partial_ms) / plain_partial_ms * 100).round(1)

# ── Storage sizes ─────────────────────────────────────────────────────────────

def table_size(conn, table)
  conn.execute("SELECT pg_size_pretty(pg_total_relation_size('#{table}'))").first['pg_size_pretty']
end

def index_size(conn, index)
  result = conn.execute("SELECT pg_size_pretty(pg_relation_size('#{index}'))").first
  result ? result['pg_size_pretty'] : 'n/a'
end

plain_size     = table_size(conn, 'plain_users')
encrypted_size = table_size(conn, 'encrypted_users')

plain_email_idx_size    = index_size(conn, 'idx_plain_email')
plain_name_trgm_size    = index_size(conn, 'idx_plain_name_trgm')
enc_email_bidx_size     = index_size(conn, 'idx_enc_email_bidx')
enc_name_bidx_arr_size  = index_size(conn, 'idx_enc_name_bidx_array')

# ── Print summary ─────────────────────────────────────────────────────────────

puts "\n"
puts "=" * 60
puts "SUMMARY  (#{ROWS} rows)"
puts "=" * 60

puts "\n--- Writes ---"
puts "  Plain insert:      #{plain_write_ms} ms total"
puts "  Encrypted insert:  #{enc_write_ms} ms total  (+#{write_overhead}% overhead)"

puts "\n--- Reads (avg per query) ---"
puts "  Exact match"
puts "    Plain (B-tree):        #{plain_exact_ms} ms"
puts "    Encrypted (blind idx): #{enc_exact_ms} ms  (+#{exact_overhead}% overhead)"
puts "  Partial match"
puts "    Plain (pg_trgm GIN):   #{plain_partial_ms} ms"
puts "    Encrypted (bidx GIN):  #{enc_partial_ms} ms  (+#{partial_overhead}% overhead)"

puts "\n--- Storage ---"
puts "  Plain table total:      #{plain_size}"
puts "  Encrypted table total:  #{encrypted_size}"
puts ""
puts "  Plain email index (B-tree):     #{plain_email_idx_size}"
puts "  Plain name index (pg_trgm GIN): #{plain_name_trgm_size}"
puts "  Encrypted email index (B-tree): #{enc_email_bidx_size}"
puts "  Encrypted name index (GIN):     #{enc_name_bidx_arr_size}"

# ── Cleanup ───────────────────────────────────────────────────────────────────

ActiveRecord::Base.remove_connection
connect('postgres').execute("DROP DATABASE #{DB}")
puts "\n==> Benchmark database dropped. Done."
