use magnus::{define_module, function, prelude::*, Error};
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

// This function takes a string and a secret key, and returns an array of hashed trigrams
fn generate_trigram_hashes(text: String, secret_key: String) -> Vec<String> {
    let mut hashes = Vec::new();
    let chars: Vec<char> = text.chars().collect();

    // If the string is less than 3 characters, we just hash the whole thing
    if chars.len() < 3 {
        hashes.push(hash_string(&text, &secret_key));
        return hashes;
    }

    // Slide a window of 3 characters across the string
    for i in 0..=(chars.len() - 3) {
        let trigram: String = chars[i..i+3].iter().collect();
        hashes.push(hash_string(&trigram, &secret_key));
    }

    hashes
}

// Helper function to create an HMAC hash
fn hash_string(data: &str, key: &str) -> String {
    let mut mac = HmacSha256::new_from_slice(key.as_bytes())
        .expect("HMAC can take key of any size");
    mac.update(data.as_bytes());
    let result = mac.finalize();
    format!("{:x}", result.into_bytes())
}

// Returns a single HMAC hash of the full value — used for exact-match blind indexing
fn generate_blind_index(text: String, secret_key: String) -> String {
    hash_string(&text, &secret_key)
}

// The Ruby initialization point
#[magnus::init]
fn init() -> Result<(), Error> {
    let module = define_module("PiiCipher")?;
    module.define_singleton_method("generate_trigram_hashes", function!(generate_trigram_hashes, 2))?;
    module.define_singleton_method("generate_blind_index", function!(generate_blind_index, 2))?;
    Ok(())
}
