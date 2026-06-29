use magnus::{function, prelude::*, Error, Ruby};
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

// Generate an array of HMAC-SHA256 hashes, one per sliding n-gram window of `n`
// characters across `text`. `n` defaults to 3 on the Ruby side (trigrams), but
// is configurable per attribute via `use_pii_cipher(..., gram_size:)`.
//
// Case-folding / normalization is handled on the Ruby side before this is
// called, so the same transformation is applied consistently on writes and
// queries. This function hashes exactly what it is given.
fn generate_ngram_hashes(text: String, secret_key: String, n: usize) -> Vec<String> {
    let mut hashes = Vec::new();

    // A window size of 0 is meaningless; return nothing rather than panic.
    if n == 0 {
        return hashes;
    }

    let chars: Vec<char> = text.chars().collect();

    // If the value is shorter than the window there are no full n-grams to
    // slide, so fall back to hashing the whole value. This keeps short values
    // (and short exact-equal search terms) matchable against each other.
    if chars.len() < n {
        hashes.push(hash_string(&text, &secret_key));
        return hashes;
    }

    // Slide a window of `n` characters across the string.
    for i in 0..=(chars.len() - n) {
        let gram: String = chars[i..i + n].iter().collect();
        hashes.push(hash_string(&gram, &secret_key));
    }

    hashes
}

// Helper function to create an HMAC-SHA256 hash, hex-encoded (lowercase).
fn hash_string(data: &str, key: &str) -> String {
    let mut mac =
        HmacSha256::new_from_slice(key.as_bytes()).expect("HMAC can take key of any size");
    mac.update(data.as_bytes());
    let result = mac.finalize();
    format!("{:x}", result.into_bytes())
}

// Returns a single HMAC hash of the full value — used for exact-match blind indexing.
fn generate_blind_index(text: String, secret_key: String) -> String {
    hash_string(&text, &secret_key)
}

// The Ruby initialization point
#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("PiiCipher")?;
    module.define_singleton_method("generate_ngram_hashes", function!(generate_ngram_hashes, 3))?;
    module.define_singleton_method("generate_blind_index", function!(generate_blind_index, 2))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "test-secret-key";

    #[test]
    fn blind_index_is_deterministic() {
        assert_eq!(
            generate_blind_index("alice@example.com".into(), KEY.into()),
            generate_blind_index("alice@example.com".into(), KEY.into())
        );
    }

    #[test]
    fn blind_index_is_key_sensitive() {
        assert_ne!(
            generate_blind_index("alice".into(), KEY.into()),
            generate_blind_index("alice".into(), "other-key".into())
        );
    }

    #[test]
    fn blind_index_is_hex_sha256_length() {
        // HMAC-SHA256 -> 32 bytes -> 64 hex chars.
        assert_eq!(generate_blind_index("x".into(), KEY.into()).len(), 64);
    }

    #[test]
    fn trigrams_produce_one_hash_per_window() {
        // "Smith" has 5 chars -> 3 trigrams (Smi, mit, ith).
        let hashes = generate_ngram_hashes("Smith".into(), KEY.into(), 3);
        assert_eq!(hashes.len(), 3);
    }

    #[test]
    fn ngram_size_is_configurable() {
        // 4-grams of "Smith" -> Smit, mith == 2 windows.
        let hashes = generate_ngram_hashes("Smith".into(), KEY.into(), 4);
        assert_eq!(hashes.len(), 2);
    }

    #[test]
    fn value_shorter_than_window_hashes_whole_value() {
        let hashes = generate_ngram_hashes("ab".into(), KEY.into(), 3);
        assert_eq!(hashes.len(), 1);
        assert_eq!(hashes[0], generate_blind_index("ab".into(), KEY.into()));
    }

    #[test]
    fn zero_window_returns_empty() {
        assert!(generate_ngram_hashes("anything".into(), KEY.into(), 0).is_empty());
    }

    #[test]
    fn ngram_hashes_match_blind_index_of_each_window() {
        let hashes = generate_ngram_hashes("abcd".into(), KEY.into(), 3);
        assert_eq!(hashes[0], generate_blind_index("abc".into(), KEY.into()));
        assert_eq!(hashes[1], generate_blind_index("bcd".into(), KEY.into()));
    }

    #[test]
    fn handles_multibyte_characters_by_scalar() {
        // 3 scalar chars -> 1 trigram window.
        let hashes = generate_ngram_hashes("áéí".into(), KEY.into(), 3);
        assert_eq!(hashes.len(), 1);
    }
}
