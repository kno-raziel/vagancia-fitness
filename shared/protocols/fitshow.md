# FitShow observation contract

Known candidate channels are FFF0: write FFF2/notify FFF1 and FFE0: write FFE1/notify FFE4. Matching UUIDs is not sufficient evidence of compatible motor control.

The independently implemented framing is `02 | payload | XOR(payload) | 03`, with bounded frame size and checksum verification. A footer byte within payload must not split a frame. Fragmented/coalesced notifications are assembled conservatively.

INFO speed-range query `0250025203` is exposed for explicit diagnostics. Received status frames preserve raw units. The isolated status query is not encoded by the implementation. Private reference-device evidence associates that query with subsequent telemetry silence; it does not establish firmware causality. Proprietary movement remains disabled.

The [synthetic vectors](../test-vectors/fitshow/frames.json) exercise delimiters, checksum and recognition. They do not initiate a device operation. The implementation uses independent framing informed by the [pinned QZ driver](https://github.com/cagnulein/qdomyos-zwift/blob/87263fb9b7b029005cba3476bdb0579273da1040/src/devices/fitshowtreadmill/fitshowtreadmill.cpp); this reference is not a grant to copy GPL code into another license.
