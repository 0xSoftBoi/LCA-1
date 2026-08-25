# SPDX-License-Identifier: Apache-2.0
"""Structural proofs for the Rev-A NTT coefficient banking rule."""

import unittest


def bank(address: int) -> int:
    return (address & 0xFF).bit_count() & 1


def row(address: int) -> int:
    return address & 0x7F


def recover_address(bank_id: int, row_id: int) -> int:
    high = bank_id ^ (row_id.bit_count() & 1)
    return (high << 7) | row_id


class TestNttParityBanking(unittest.TestCase):
    def test_mapping_is_bijective(self) -> None:
        locations = {(bank(address), row(address)) for address in range(256)}
        self.assertEqual(len(locations), 256)
        for address in range(256):
            self.assertEqual(recover_address(bank(address), row(address)), address)

    def test_every_radix2_butterfly_uses_opposite_banks(self) -> None:
        # Covers the complete stage set used by the ML-DSA schedule. ML-KEM is
        # the same prefix and stops before len=1.
        for length in (128, 64, 32, 16, 8, 4, 2, 1):
            for start in range(0, 256, 2 * length):
                for j in range(start, start + length):
                    peer = j + length
                    self.assertLess(peer, 256)
                    self.assertNotEqual(
                        bank(j),
                        bank(peer),
                        msg=f"len={length} pair=({j},{peer}) aliases bank {bank(j)}",
                    )

    def test_each_butterfly_has_exactly_one_access_per_bank(self) -> None:
        for length in (128, 64, 32, 16, 8, 4, 2, 1):
            for start in range(0, 256, 2 * length):
                for j in range(start, start + length):
                    pair = (j, j + length)
                    counts = [sum(bank(address) == b for address in pair) for b in (0, 1)]
                    self.assertEqual(counts, [1, 1])


if __name__ == "__main__":
    unittest.main()
