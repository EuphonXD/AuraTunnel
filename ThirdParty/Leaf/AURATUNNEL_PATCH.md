# AuraTunnel Leaf integration

- Upstream: `https://github.com/eycorsican/leaf`
- Pinned commit: `1d20301570395cff1db5f3e316222b0ec3b4732e`
- License: Apache-2.0 (`LICENSE` in this directory)

AuraTunnel adds a bounded FFI packet bridge selected by TUN fd `-2`. This is
used instead of extracting `NEPacketTunnelFlow`'s private socket file
descriptor. The bridge accepts the batches returned by Apple's public
`readPackets` API and sends generated packets back through a synchronous
callback for batched `writePackets` calls.

The JSON converter deliberately preserves the `-2` sentinel and the TUN
inbound selects the PacketFlow bridge before constructing an OS TUN
configuration. This ordering is required: treating the bridge as a generic
negative fd attempts to parse absent device gateway fields and can terminate
the extension process. `leaf-ffi` includes a start/running/shutdown regression
test for this path.

The FFI validates in-memory JSON before start and exposes an explicit
callback-clear API so tunnel shutdown cannot leave a dangling Swift context.

AuraTunnel also exposes Leaf's existing legacy VMess header path when an
imported node has a non-zero `alterId`. The `legacy-` marker changes only the
VMess header mode; packet body encryption remains AES-GCM or ChaCha20-Poly1305.

The `auratunnel-ios` feature excludes Leaf's API server, automatic config
watcher, QUIC, Reality and unused inbound protocols to reduce extension binary
size, worker count and memory pressure.
