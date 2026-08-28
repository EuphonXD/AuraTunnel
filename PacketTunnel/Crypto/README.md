# Crypto boundary

AuraTunnel uses the explicitly approved Leaf core for proxy-protocol crypto.
Leaf's iOS build selects ring's ARM-optimized AES-GCM/ChaCha implementations;
no encryption runs in Swift's packet loop. Credentials stay in the shared
Keychain access group, never in App Group `UserDefaults` or provider settings.
