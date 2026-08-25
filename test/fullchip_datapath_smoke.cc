// SPDX-License-Identifier: Apache-2.0
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

#define cxxrtl_design_create cxxrtl_keccak_design_create
#include "keccak.cc"
#undef cxxrtl_design_create
#define cxxrtl_design_create cxxrtl_ntt_design_create
#include "ntt.cc"
#undef cxxrtl_design_create

using cxxrtl_design::p_lca__keccak__f1600;
using cxxrtl_design::p_lca__ntt__accel;

extern "C" {
void PQCLEAN_MLDSA65_CLEAN_ntt(int32_t *values);
void PQCLEAN_MLDSA65_CLEAN_invntt_tomont(int32_t *values);
void PQCLEAN_MLKEM768_CLEAN_ntt(int16_t *values);
void PQCLEAN_MLKEM768_CLEAN_invntt(int16_t *values);
}

namespace {

uint32_t rng_state = 0x4c434132u;

uint32_t next_random() {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

[[noreturn]] void fail(const std::string &message) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
}

template <typename Top>
void tick(Top &top) {
    top.p_clk__i.template set<uint32_t>(0);
    top.step();
    top.p_clk__i.template set<uint32_t>(1);
    top.step();
}

template <typename Top>
void reset(Top &top) {
    top.p_clk__i.template set<uint32_t>(0);
    top.p_rst__ni.template set<uint32_t>(0);
    top.p_zeroize__i.template set<uint32_t>(0);
    top.p_start__i.template set<uint32_t>(0);
    top.step();
    tick(top);
    top.p_rst__ni.template set<uint32_t>(1);
    top.step();
}

uint64_t rotl64(uint64_t value, unsigned int amount) {
    return amount == 0 ? value : (value << amount) | (value >> (64 - amount));
}

void keccak_reference(std::array<uint64_t, 25> &state) {
    static constexpr uint64_t rc[24] = {
        0x0000000000000001ULL, 0x0000000000008082ULL,
        0x800000000000808aULL, 0x8000000080008000ULL,
        0x000000000000808bULL, 0x0000000080000001ULL,
        0x8000000080008081ULL, 0x8000000000008009ULL,
        0x000000000000008aULL, 0x0000000000000088ULL,
        0x0000000080008009ULL, 0x000000008000000aULL,
        0x000000008000808bULL, 0x800000000000008bULL,
        0x8000000000008089ULL, 0x8000000000008003ULL,
        0x8000000000008002ULL, 0x8000000000000080ULL,
        0x000000000000800aULL, 0x800000008000000aULL,
        0x8000000080008081ULL, 0x8000000000008080ULL,
        0x0000000080000001ULL, 0x8000000080008008ULL,
    };
    static constexpr unsigned int rho[25] = {
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20,
        3, 10, 43, 25, 39, 41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    };

    for (unsigned int round = 0; round < 24; ++round) {
        std::array<uint64_t, 5> c{};
        std::array<uint64_t, 5> d{};
        std::array<uint64_t, 25> a{};
        std::array<uint64_t, 25> b{};
        for (unsigned int x = 0; x < 5; ++x) {
            for (unsigned int y = 0; y < 5; ++y)
                c[x] ^= state[x + 5 * y];
        }
        for (unsigned int x = 0; x < 5; ++x)
            d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
        for (unsigned int x = 0; x < 5; ++x) {
            for (unsigned int y = 0; y < 5; ++y) {
                const unsigned int lane = x + 5 * y;
                a[lane] = state[lane] ^ d[x];
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(a[lane], rho[lane]);
            }
        }
        for (unsigned int x = 0; x < 5; ++x) {
            for (unsigned int y = 0; y < 5; ++y) {
                const unsigned int lane = x + 5 * y;
                state[lane] = b[lane] ^ ((~b[(x + 1) % 5 + 5 * y]) &
                                          b[(x + 2) % 5 + 5 * y]);
            }
        }
        state[0] ^= rc[round];
    }
}

void write_keccak_word(p_lca__keccak__f1600 &top, unsigned int address,
                       uint32_t value) {
    top.p_state__word__addr__i.set<uint32_t>(address);
    top.p_state__wdata__i.set<uint32_t>(value);
    top.p_state__wstrb__i.set<uint32_t>(0xf);
    top.p_state__we__i.set<uint32_t>(1);
    tick(top);
    top.p_state__we__i.set<uint32_t>(0);
    top.step();
}

uint32_t read_keccak_word(p_lca__keccak__f1600 &top, unsigned int address) {
    top.p_state__word__addr__i.set<uint32_t>(address);
    top.step();
    return top.p_state__rdata__o.get<uint32_t>();
}

void test_keccak() {
    p_lca__keccak__f1600 top;
    reset(top);
    top.p_state__we__i.set<uint32_t>(0);
    top.p_state__wstrb__i.set<uint32_t>(0);

    for (unsigned int vector = 0; vector < 16; ++vector) {
        std::array<uint64_t, 25> expected{};
        for (unsigned int lane = 0; lane < 25; ++lane) {
            expected[lane] = static_cast<uint64_t>(next_random()) |
                             (static_cast<uint64_t>(next_random()) << 32);
            write_keccak_word(top, 2 * lane, static_cast<uint32_t>(expected[lane]));
            write_keccak_word(top, 2 * lane + 1, static_cast<uint32_t>(expected[lane] >> 32));
        }
        keccak_reference(expected);

        top.p_start__i.set<uint32_t>(1);
        tick(top);
        top.p_start__i.set<uint32_t>(0);
        unsigned int cycles = 0;
        while (top.p_busy__o.get<uint32_t>() != 0 && cycles < 30) {
            tick(top);
            ++cycles;
        }
        if (cycles != 24 || top.p_done__o.get<uint32_t>() == 0)
            fail("Keccak permutation latency/status mismatch");
        for (unsigned int lane = 0; lane < 25; ++lane) {
            uint64_t actual = read_keccak_word(top, 2 * lane) |
                (static_cast<uint64_t>(read_keccak_word(top, 2 * lane + 1)) << 32);
            if (actual != expected[lane])
                fail("Keccak state mismatch at vector " + std::to_string(vector) +
                     ", lane " + std::to_string(lane));
        }
    }
}

void write_ntt_word(p_lca__ntt__accel &top, unsigned int address,
                    uint32_t value) {
    top.p_coeff__addr__i.set<uint32_t>(address);
    top.p_coeff__wdata__i.set<uint32_t>(value);
    top.p_coeff__wstrb__i.set<uint32_t>(0xf);
    top.p_coeff__we__i.set<uint32_t>(1);
    tick(top);
    top.p_coeff__we__i.set<uint32_t>(0);
    top.step();
}

uint32_t read_ntt_word(p_lca__ntt__accel &top, unsigned int address) {
    // Rev-A NTT storage is synchronous 1RW SRAM. Present the logical address
    // for one full idle clock before sampling the registered output.
    top.p_coeff__addr__i.set<uint32_t>(address);
    top.p_coeff__we__i.set<uint32_t>(0);
    tick(top);
    return top.p_coeff__rdata__o.get<uint32_t>();
}

unsigned int run_ntt(p_lca__ntt__accel &top, unsigned int command) {
    top.p_command__i.set<uint32_t>(command);
    top.p_start__i.set<uint32_t>(1);
    tick(top);
    top.p_start__i.set<uint32_t>(0);
    unsigned int cycles = 0;
    while (top.p_busy__o.get<uint32_t>() != 0 && cycles < 3000) {
        tick(top);
        ++cycles;
    }
    if (top.p_done__o.get<uint32_t>() == 0)
        fail("NTT timeout/status mismatch for command " + std::to_string(command));
    return cycles;
}

void test_ntt() {
    p_lca__ntt__accel top;
    reset(top);
    top.p_coeff__we__i.set<uint32_t>(0);
    top.p_coeff__wstrb__i.set<uint32_t>(0);
    std::array<unsigned int, 4> latency{};

    for (unsigned int command = 0; command < 4; ++command) {
        for (unsigned int vector = 0; vector < 8; ++vector) {
            if (command < 2) {
                std::array<int32_t, 256> expected{};
                for (unsigned int i = 0; i < expected.size(); ++i) {
                    expected[i] = static_cast<int32_t>(next_random() % 8380417u) - 4190208;
                    write_ntt_word(top, i, static_cast<uint32_t>(expected[i]));
                }
                if (command == 0)
                    PQCLEAN_MLDSA65_CLEAN_ntt(expected.data());
                else
                    PQCLEAN_MLDSA65_CLEAN_invntt_tomont(expected.data());
                const unsigned int cycles = run_ntt(top, command);
                if (latency[command] == 0) latency[command] = cycles;
                if (latency[command] != cycles) fail("ML-DSA NTT latency varied");
                for (unsigned int i = 0; i < expected.size(); ++i) {
                    if (static_cast<int32_t>(read_ntt_word(top, i)) != expected[i])
                        fail("ML-DSA NTT mismatch, command " + std::to_string(command) +
                             ", coefficient " + std::to_string(i));
                }
            } else {
                std::array<int16_t, 256> expected{};
                for (unsigned int i = 0; i < expected.size(); ++i) {
                    expected[i] = static_cast<int16_t>(next_random() % 3329u) - 1664;
                    write_ntt_word(top, i, static_cast<uint32_t>(static_cast<int32_t>(expected[i])));
                }
                if (command == 2)
                    PQCLEAN_MLKEM768_CLEAN_ntt(expected.data());
                else
                    PQCLEAN_MLKEM768_CLEAN_invntt(expected.data());
                const unsigned int cycles = run_ntt(top, command);
                if (latency[command] == 0) latency[command] = cycles;
                if (latency[command] != cycles) fail("ML-KEM NTT latency varied");
                for (unsigned int i = 0; i < expected.size(); ++i) {
                    if (static_cast<int16_t>(read_ntt_word(top, i)) != expected[i])
                        fail("ML-KEM NTT mismatch, command " + std::to_string(command) +
                             ", coefficient " + std::to_string(i));
                }
            }
        }
    }
    std::cout << "NTT cycles: ML-DSA fwd=" << latency[0]
              << " inv=" << latency[1]
              << ", ML-KEM fwd=" << latency[2]
              << " inv=" << latency[3] << "\n";
}

} // namespace

int main() {
    test_keccak();
    test_ntt();
    std::cout << "PASS: Keccak and both Level-3 NTT datapaths match independent software\n";
    return 0;
}
