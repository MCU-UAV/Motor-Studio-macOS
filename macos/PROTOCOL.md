# J288/S288 protocol evidence

## Sources

- Original distribution: `unitreerobotics/Unitree-Motor-Assistant`, commit `37ea172c9a8cbba854bd4af7573d328dbd9e5176`.
- Official public protocol / C example: [digital_servo](https://github.com/unitreerobotics/digital_servo/tree/75c1ed63579dc7bb759e2990bd4b804c11b57daf), particularly `stm32/firmware/App/protocol.h`, `protocol.c`, `crc_ccitt.h`, `specs/protocol.md`.
- Official example README describes research / education / DIY use and directs commercial mass-production users to Unitree. This implementation independently encodes the wire format; no example source or CRC table is copied.
- Real SDK command outputs: `Tests/MotorCoreTests/Fixtures/sdk-vectors.json`, obtained by loading the embedded `UnitreeMotorSDK.dll` under Windows Python / Wine and calling only object creation, in-memory setters and packet generation. No serial connection or physical motor was used.

## Layout

All multibyte integers are little endian. A control frame is 20 bytes:

| Offset | Type | Meaning |
|---|---|---|
| 0 | 2 bytes | `FE EE` |
| 2 | UInt8 | ID bits 0–3; mode bits 4–6; timeout protection bit 7 |
| 3 | UInt8 | Reserved zero |
| 4 | Int16 | Torque |
| 6 | Int16 | Speed |
| 8 | Int32 | Position |
| 12 | Int16 | Kp |
| 14 | Int16 | Kd |
| 16 | UInt32 | CRC of bytes 0–15 |

Feedback is 26 bytes: `FC EE`; mode/ID/timeout at 2; signed shell temperature at 3; unsigned winding temperature at 4; **UInt8 voltage at 5**; Int16 torque at 6; Int16 speed at 8; Int32 position at 10; UInt32 errors at 14; UInt16 encoder position (low 13 bits) / warning (top 3 bits) at 18; two reserved bytes at 20–21; CRC at 22–25, covering bytes 2–21.

CRC polynomial `0x04C11DB7`, initial `0xFFFFFFFF`, no final XOR. Process each little-endian UInt32 MSB first. Do not use standard byte-stream/zlib CRC32. For normal control/feedback, CRC inputs are 16 or 20 bytes; Boot packets use their variable aligned length.

## Conversion

`R = 70070 / 243`. Input values are output-shaft quantities:

- Torque: `T * 256000 / R`
- Speed: `W * (2.56 / (2π)) * R`
- Position: `P * (32768 / (2π)) * R`
- Kp: `Kp * 1280000 / R / R`
- Kd: `Kd * 128000000 / R / R`

Truncate toward zero to match the **actual distributed SDK**. Physical input ranges are validated first. Only tiny endpoint differences from published rounded bounds may clamp at integer limits. These are representation limits, not rated motor loads.

## Discrepancies resolved

1. Public Markdown says feedback voltage is UInt16, inconsistent with its 26-byte total. The C packed struct and real layout use UInt8.
2. Public Python uses signed `b` for winding temperature and voltage; C defines UInt8. This client preserves values above 127.
3. Public Python uses unsigned `I` for desired position, preventing negative values. C and the SDK use Int32.
4. Public Python rounds. The actual SDK truncates; e.g. 0.1 N·m gives torque raw 88. Both positive and negative SDK fixtures confirm this.
5. The original SDK Stop/timeout=0 frame is `feee0000...80462079`; Stop/timeout=1 is `feee8000...1d99fb6e`. Earlier native startup used only timeout=1 and omitted clearing the latched watchdog. The official [protocol.h, RIS_Mode_t](https://github.com/unitreerobotics/digital_servo/blob/75c1ed63579dc7bb759e2990bd4b804c11b57daf/stm32/firmware/App/protocol.h#L24) explicitly says `触发超时保护(需要控制位发0清除)`. Encoding both frames in fixtures did not test this state transition.

## Startup timeout-latch handshake

Every real unicast session, including restart and asynchronous acquisition, first sends each ID a Stop frame with all five control parameters zero and timeout=0. It immediately sends Stop/zero with timeout=1 and validates matching ID, CRC, Stop mode, error=0 and timeout status cleared. Only after every target succeeds can the acquisition engine send FOC commands; all running commands enforce timeout=1, including mailbox updates.

If the clear response is missing/invalid or the task is cancelled, a bounded, cancellation-independent protected Stop is still attempted. Failure of either step aborts startup. A timeout during running still stops the engine; there is no automatic clear-and-resume and no ignored alarm. This is separate from Clear_Error (private mode 6), which does not replace the timeout-bit handshake.

Broadcast lacks individual acknowledgements, so real broadcast startup is rejected rather than treating a sent packet as successful preparation. Selected-ID unified control remains available. Broadcast Stop and demo send-only behavior remain available. UI display scheduling stays at 20 Hz and is not used to time this handshake.

## Limits of validation

Transmit encoding has binary-derived fixtures. Receive decoding uses the published C layout and synthetic tests, not captured hardware replies. Private configuration and APP OTA have been reconstructed from the embedded SDK; see [PRIVATE-PROTOCOL.md](PRIVATE-PROTOCOL.md). Their RX fixtures are synthetic and their hardware behavior remains unverified. The protocol has no transaction sequence, so requests are serialized, stale input is discarded before each request, CRC and matching ID are required; a delayed response from the same ID cannot be distinguished perfectly. Never have two controllers on the same bus.

## Native control options

ID 15 is broadcast and is send-only; it never increments received or creates feedback samples. Stop broadcasts first and then verifies known IDs. Output and rotor input are selectable: rotor position/speed = output × R; rotor torque = output / R; rotor Kp/Kd = output / R². Direct rotor encoding uses the same raw formulas with R=1. Range errors are rejected rather than copying the SDK's silent saturation. Actual `Set_Control_Data_Rotor` and ID 15 packets are in `parity-vectors.json`.

The asynchronous mode separates `beginAsync` and nonblocking `receiveAsync`. It preserves fragmented frames, permits one pending request, and releases it on timeout/cancel/stop; no sequence field exists for matching overlapping commands. `SessionTests` exercise this state using a simulated serial driver; Darwin I/O remains unverified on hardware.

## Continued state audit

Before each unicast FOC write, SerialSession requires healthy feedback from a prepared ID within 500 ms. Stop, disconnect, maintenance and failed preparation revoke that state. The real acquisition loop rejects per-ID target periods >=500 ms, checks returned mode against the command, and does not automatically resume after a watchdog fault. This is application timing margin beneath the documented ~1 s device watchdog, unrelated to 20 Hz UI refresh.

A failed broadcast Stop no longer skips unicast Stop attempts. State-changing maintenance failure closes the descriptor because an ACK loss is not evidence of rollback. See [state audit](Docs/STATE-AUDIT.md) for tests and hardware limits.
