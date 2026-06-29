# frozen_string_literal: true

RSpec.describe PiiCipher do
  let(:secret) { "test-secret-key-not-for-production" }

  it "has a version number" do
    expect(PiiCipher::VERSION).not_to be_nil
  end

  describe ".generate_blind_index (Rust)" do
    it "is deterministic for the same input and key" do
      expect(described_class.generate_blind_index("alice@example.com", secret))
        .to eq(described_class.generate_blind_index("alice@example.com", secret))
    end

    it "produces a 64-char lowercase hex HMAC-SHA256 digest" do
      digest = described_class.generate_blind_index("alice", secret)
      expect(digest).to match(/\A[0-9a-f]{64}\z/)
    end

    it "changes when the key changes" do
      expect(described_class.generate_blind_index("alice", secret))
        .not_to eq(described_class.generate_blind_index("alice", "other-key"))
    end
  end

  describe ".generate_ngram_hashes (Rust)" do
    it "produces one hash per sliding window (trigrams by default)" do
      # "smith" -> smi, mit, ith
      expect(described_class.generate_ngram_hashes("smith", secret, 3).length).to eq(3)
    end

    it "honors a configurable window size" do
      # "smith" 4-grams -> smit, mith
      expect(described_class.generate_ngram_hashes("smith", secret, 4).length).to eq(2)
    end

    it "hashes the whole value when it is shorter than the window" do
      hashes = described_class.generate_ngram_hashes("ab", secret, 3)
      expect(hashes.length).to eq(1)
      expect(hashes.first).to eq(described_class.generate_blind_index("ab", secret))
    end

    it "each window equals the blind index of that substring" do
      hashes = described_class.generate_ngram_hashes("abcd", secret, 3)
      expect(hashes[0]).to eq(described_class.generate_blind_index("abc", secret))
      expect(hashes[1]).to eq(described_class.generate_blind_index("bcd", secret))
    end
  end

  describe ".normalize" do
    it "downcases by default (case-insensitive search)" do
      expect(described_class.normalize("Smith", partial: true, case_sensitive: false))
        .to eq("smith")
    end

    it "preserves case when case_sensitive is true" do
      expect(described_class.normalize("Smith", partial: true, case_sensitive: true))
        .to eq("Smith")
    end
  end

  describe ".secret_key" do
    it "returns the configured key" do
      expect(described_class.secret_key).to eq(secret)
    end

    it "raises a clear error when unset" do
      original = ENV.delete("PII_SECRET_KEY")
      expect { described_class.secret_key }.to raise_error(PiiCipher::MissingSecretKeyError)
    ensure
      ENV["PII_SECRET_KEY"] = original
    end
  end
end
