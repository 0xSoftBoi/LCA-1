# LCA-1 host command ABI 2.0

All control registers are little-endian 32-bit APB4 words. `pready_o` is always
asserted and `pslverr_o` is always deasserted in the portable RTL. A platform
wrapper may add bus-level wait states but must preserve the register semantics.

## Register map

| offset | access | name | description |
| ---: | --- | --- | --- |
| `0x00` | R | `IDENTITY` | `0x4c434131` (`LCA1`) |
| `0x04` | R | `ABI_VERSION` | `0x00020000` (2.0) |
| `0x08` | R | `CAPABILITIES` | `0x1f`: verify, decaps, streams, zeroize, context |
| `0x0c` | R | `STATUS` | status bits below |
| `0x10` | R/W | `COMMAND` | selected command byte |
| `0x14` | W | `CONTROL` | start/acknowledge/clear/zeroize pulses |
| `0x18` | R | `MESSAGE_LENGTH` | accepted message bytes |
| `0x1c` | R | `CONTEXT_LENGTH` | accepted context bytes |
| `0x20` | R | `LOADED_MASK` | one bit per input tag |
| `0x24` | R | `RESULT_CODE` | completion or frontend error code |
| `0x28` | R | `RESULT_LENGTH` | bulk output bytes; zero or 32 in ABI 2.0 |
| `0x2c` | R | `CYCLES_LO` | low 32 operation-busy clocks |
| `0x30` | R | `CYCLES_HI` | high 32 operation-busy clocks |
| `0x34` | R | `ACTIVE_COMMAND` | command whose completion is being reported |
| `0x40..0x5c` | R | `RESULT_WORD[0..7]` | latched output words; normally use output stream |

`STATUS` bits are:

| bit | name | meaning |
| ---: | --- | --- |
| 0 | `BUSY` | command accepted and not yet committed by firmware |
| 1 | `DONE` | completion is latched |
| 2 | `ERROR` | frontend/internal result code is `0x80` or greater |
| 3 | `VERIFY_VALID` | completed ML-DSA command returned valid |
| 4 | `OUTPUT_ACTIVE` | ML-KEM result is waiting on the output stream |
| 5 | `COMMAND_PENDING` | firmware has not yet claimed the command |
| 6 | `ANY_INPUT_LOADED` | at least one loaded-mask bit is set |
| 7 | `INGRESS_ERROR` | a malformed input beat or length was observed |

`irq_o` is level-sensitive and equals `DONE || ERROR`. It remains asserted
until the host acknowledges the completion or requests zeroization.

## Control writes

`CONTROL` bits are independent. Software normally uses separate writes during
bring-up and may combine `ACK_RESULT | CLEAR_INPUTS` after a completed command.

| bit | name | action |
| ---: | --- | --- |
| 0 | `START` | validate and launch the selected command |
| 1 | `ACK_RESULT` | clear done/error/verify state and overwrite result words |
| 2 | `CLEAR_INPUTS` | reset all byte counts and loaded metadata before reloading |
| 3 | `ZEROIZE` | request whole-SRAM scrub and firmware reboot |

`ACK_RESULT` and `CLEAR_INPUTS` are ignored while `BUSY=1`. `ZEROIZE` is always
honored. A start while busy or pending returns `RESULT_BUSY` without modifying
the active command.

## Commands

| value | command | required loaded bits | output |
| ---: | --- | --- | --- |
| `0x01` | ML-DSA-65 verify | tags 0, 1, 2, 3 | `VERIFY_VALID` and result code |
| `0x02` | ML-KEM-768 decapsulate | tags 4, 5 | 32-byte output stream |
| `0x03` | SHAKE256 known-answer self-test | none | result code |

## Result codes

| value | meaning | `ERROR` |
| ---: | --- | --- |
| `0x00` | success / valid signature | no |
| `0x01` | invalid ML-DSA signature | no |
| `0x80` | unknown command | yes |
| `0x81` | missing object, wrong length, or malformed stream | yes |
| `0x82` | command already busy/pending | yes |
| `0x83` | internal firmware error | yes |
| `0x84` | self-test failure | yes |

An invalid signature is a normal cryptographic result rather than an internal
chip error. ML-KEM ciphertext failure uses implicit rejection and still returns
`0x00` with a pseudorandom 32-byte secret, as required by the algorithm.

## Tagged input stream

The input channel uses `s_valid_i`, `s_ready_o`, `s_data_i[31:0]`,
`s_keep_i[3:0]`, `s_last_i`, and `s_kind_i[2:0]`.

| tag | object | length rule | SRAM CPU address |
| ---: | --- | --- | --- |
| `0` | ML-DSA-65 public key | exactly 1,952 | `0x1006_0000` |
| `1` | ML-DSA-65 signature | exactly 3,309 | `0x1006_0800` |
| `2` | message | 0 to 65,536 | `0x1006_1600` |
| `3` | context | 0 to 255 | `0x1007_1600` |
| `4` | ML-KEM-768 decapsulation key | exactly 2,400 | `0x1007_1700` |
| `5` | ML-KEM-768 ciphertext | exactly 1,088 | `0x1007_2080` |
| `6..7` | reserved | rejected | — |

Data is little-endian within each word. Every non-final beat must set
`s_keep_i=4'b1111`. The final beat must use one of `0001`, `0011`, `0111`, or
`1111`, with valid bytes contiguous from bit zero. A zero or non-contiguous
mask poisons the transaction.

On reset or `CLEAR_INPUTS`, the message and context loaded bits default to one
with length zero. This is how the host selects the valid empty values without
sending a zero-byte beat. Sending the first non-empty message/context beat
replaces that default. The host must send exactly one terminal `s_last_i` per
object and must clear inputs before reusing a tag for a new command. Tags may
be interleaved, although contiguous objects are recommended.

The frontend disables ingress while `BUSY=1`. It raises `s_ready_o` for a valid
tag whenever idle and not zeroizing. A beat is accepted on
`s_valid_i && s_ready_o`.

## Output stream

Only successful ML-KEM decapsulation produces bulk output. The channel uses
`m_valid_o`, `m_ready_i`, `m_data_o[31:0]`, `m_keep_o[3:0]`, and `m_last_o`.
ABI 2.0 emits eight little-endian words, every beat has `m_keep_o=0xf`, and the
eighth beat has `m_last_o=1`.

The result remains stable under backpressure. `OUTPUT_ACTIVE` remains high
until the eighth handshake. A host timeout should be treated as a failure and
followed by `ZEROIZE`; partial secrets must never be consumed.

## Normal host sequences

ML-KEM decapsulation:

1. Wait for `BUSY=0`; write `ACK_RESULT | CLEAR_INPUTS` if reusing the chip.
2. Stream tag 4 and tag 5 with exact lengths.
3. Write command `0x02`, then write `START`.
4. Wait for IRQ and require `RESULT_CODE=0`, `RESULT_LENGTH=32`.
5. Consume exactly eight output beats.
6. Write `ACK_RESULT`, then request `ZEROIZE` when the decapsulation key is no
   longer needed.

ML-DSA verification:

1. Clear old result and input metadata.
2. Stream tags 0 and 1, plus message/context tags 2 and 3 when non-empty.
3. Write command `0x01`, then `START`.
4. Wait for IRQ. Accept only `RESULT_CODE=0 && VERIFY_VALID=1` as valid.
5. Treat `RESULT_CODE=1` as an invalid signature and all `>=0x80` values as
   chip/integration errors.
