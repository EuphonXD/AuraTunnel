pub mod datagram;
pub mod stream;

pub use datagram::Handler as DatagramHandler;
pub use stream::Handler as StreamHandler;

/// AuraTunnel prefixes the body cipher for legacy VMess nodes whose imported
/// alterId is non-zero. Leaf already contains the legacy request/response header
/// implementation; upstream simply hard-coded the modern AEAD mode at its two
/// call sites.
pub(crate) fn security_mode(security: &str) -> (bool, &str) {
    match security.strip_prefix("legacy-") {
        Some(cipher) => (false, cipher),
        None => (true, security),
    }
}

#[cfg(test)]
mod tests {
    use super::security_mode;

    #[test]
    fn selects_legacy_header_without_changing_body_cipher() {
        assert_eq!(security_mode("legacy-aes-128-gcm"), (false, "aes-128-gcm"));
        assert_eq!(security_mode("aes-128-gcm"), (true, "aes-128-gcm"));
    }
}

use super::crypto;
use super::protocol;
use super::stream as vmess_stream;
