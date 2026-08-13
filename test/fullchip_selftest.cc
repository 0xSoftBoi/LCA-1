// SPDX-License-Identifier: Apache-2.0
// Boots the real RV32 firmware in the complete CXXRTL SoC and runs its
// hardware-backed SHAKE256 known-answer self-test through the host ABI.

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

#include "chip_top.cc"

extern "C" {
#include "../third_party/PQClean/crypto_kem/ml-kem-768/clean/api.h"
#include "../third_party/PQClean/crypto_sign/ml-dsa-65/clean/api.h"
}

using cxxrtl_design::p_lca__chip__top;

namespace {

uint64_t random_state = UINT64_C(0x6c6361315f736f63);

[[noreturn]] void fail(const std::string &message) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
}

void tick(p_lca__chip__top &top) {
    top.p_clk__i.set<uint32_t>(0);
    top.step();
    top.p_clk__i.set<uint32_t>(1);
    top.step();
}

void initialize(p_lca__chip__top &top) {
    top.p_clk__i.set<uint32_t>(0);
    top.p_rst__ni.set<uint32_t>(0);
    top.p_tamper__i.set<uint32_t>(0);
    top.p_paddr__i.set<uint32_t>(0);
    top.p_psel__i.set<uint32_t>(0);
    top.p_penable__i.set<uint32_t>(0);
    top.p_pwrite__i.set<uint32_t>(0);
    top.p_pwdata__i.set<uint32_t>(0);
    top.p_pstrb__i.set<uint32_t>(0xf);
    top.p_s__valid__i.set<uint32_t>(0);
    top.p_s__kind__i.set<uint32_t>(0);
    top.p_s__data__i.set<uint32_t>(0);
    top.p_s__keep__i.set<uint32_t>(0);
    top.p_s__last__i.set<uint32_t>(0);
    top.p_m__ready__i.set<uint32_t>(0);
    top.p_entropy__valid__i.set<uint32_t>(0);
    top.p_entropy__data__i.set<uint32_t>(0);
    top.step();
    for (unsigned int i = 0; i < 4; ++i)
        tick(top);
    top.p_rst__ni.set<uint32_t>(1);
    top.step();
}

void apb_write(p_lca__chip__top &top, uint32_t address,
               uint32_t value) {
    top.p_paddr__i.set<uint32_t>(address);
    top.p_pwdata__i.set<uint32_t>(value);
    top.p_pstrb__i.set<uint32_t>(0xf);
    top.p_psel__i.set<uint32_t>(1);
    top.p_penable__i.set<uint32_t>(1);
    top.p_pwrite__i.set<uint32_t>(1);
    top.step();
    if (top.p_pready__o.get<uint32_t>() == 0)
        fail("APB slave did not respond");
    tick(top);
    top.p_psel__i.set<uint32_t>(0);
    top.p_penable__i.set<uint32_t>(0);
    top.p_pwrite__i.set<uint32_t>(0);
    top.step();
}

uint32_t apb_read(p_lca__chip__top &top, uint32_t address) {
    top.p_paddr__i.set<uint32_t>(address);
    top.p_psel__i.set<uint32_t>(1);
    top.p_penable__i.set<uint32_t>(1);
    top.p_pwrite__i.set<uint32_t>(0);
    top.step();
    const uint32_t value = top.p_prdata__o.get<uint32_t>();
    top.p_psel__i.set<uint32_t>(0);
    top.p_penable__i.set<uint32_t>(0);
    top.step();
    return value;
}

void stream_buffer(p_lca__chip__top &top, uint32_t kind,
                   const uint8_t *data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        const size_t remaining = length - offset;
        const size_t beat_bytes = remaining < 4 ? remaining : 4;
        uint32_t word = 0;
        for (size_t byte = 0; byte < beat_bytes; ++byte)
            word |= static_cast<uint32_t>(data[offset + byte]) << (8 * byte);

        top.p_s__kind__i.set<uint32_t>(kind);
        top.p_s__data__i.set<uint32_t>(word);
        top.p_s__keep__i.set<uint32_t>((1u << beat_bytes) - 1u);
        top.p_s__last__i.set<uint32_t>(offset + beat_bytes == length);
        top.p_s__valid__i.set<uint32_t>(1);
        top.step();
        if (top.p_s__ready__o.get<uint32_t>() == 0)
            fail("whole-chip input stream unexpectedly backpressured");
        tick(top);
        offset += beat_bytes;
    }
    top.p_s__valid__i.set<uint32_t>(0);
    top.p_s__last__i.set<uint32_t>(0);
    top.p_s__keep__i.set<uint32_t>(0);
    top.step();
}

uint32_t wait_for_completion(p_lca__chip__top &top, uint32_t timeout_cycles,
                             const char *operation) {
    uint32_t elapsed = 0;
    while (top.p_irq__o.get<uint32_t>() == 0 && elapsed < timeout_cycles) {
        tick(top);
        ++elapsed;
        if (top.p_firmware__trap__o.get<uint32_t>() != 0)
            fail(std::string("firmware CPU trapped during ") + operation);
    }
    if (elapsed == timeout_cycles)
        fail(std::string(operation) + " timed out");
    return elapsed;
}

uint64_t read_operation_cycles(p_lca__chip__top &top) {
    return static_cast<uint64_t>(apb_read(top, 0x2c)) |
           (static_cast<uint64_t>(apb_read(top, 0x30)) << 32);
}

void acknowledge_and_clear(p_lca__chip__top &top) {
    apb_write(top, 0x14, 0x06); // acknowledge result and clear input metadata
    if ((apb_read(top, 0x0c) & 0x3fu) != 0 ||
        apb_read(top, 0x20) != 0x0cu)
        fail("host state did not clear between commands");
}

void launch(p_lca__chip__top &top, uint32_t command) {
    apb_write(top, 0x10, command);
    apb_write(top, 0x14, 1);
    if (top.p_busy__o.get<uint32_t>() == 0)
        fail("whole-chip command launch was not accepted");
}

std::array<uint8_t, 32> read_shared_secret(p_lca__chip__top &top) {
    std::array<uint8_t, 32> secret{};
    top.p_m__ready__i.set<uint32_t>(1);
    for (size_t word_index = 0; word_index < 8; ++word_index) {
        top.step();
        if (top.p_m__valid__o.get<uint32_t>() == 0 ||
            top.p_m__keep__o.get<uint32_t>() != 0xf ||
            top.p_m__last__o.get<uint32_t>() != (word_index == 7))
            fail("whole-chip shared-secret framing mismatch");
        const uint32_t word = top.p_m__data__o.get<uint32_t>();
        for (size_t byte = 0; byte < 4; ++byte)
            secret[4 * word_index + byte] =
                static_cast<uint8_t>(word >> (8 * byte));
        tick(top);
    }
    top.p_m__ready__i.set<uint32_t>(0);
    top.step();
    return secret;
}

} // namespace

extern "C" int PQCLEAN_randombytes(uint8_t *output, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        random_state ^= random_state >> 12;
        random_state ^= random_state << 25;
        random_state ^= random_state >> 27;
        output[i] = static_cast<uint8_t>(
            (random_state * UINT64_C(0x2545f4914f6cdd1d)) >> 56);
    }
    return 0;
}

int main() {
    p_lca__chip__top top;
    initialize(top);

    if (apb_read(top, 0x00) != 0x4c434131u)
        fail("integrated chip identity mismatch");

    launch(top, 3); // firmware/hardware SHAKE256 known-answer self-test
    const uint32_t selftest_elapsed =
        wait_for_completion(top, 500000, "boot/self-test");

    const uint32_t status = apb_read(top, 0x0c);
    const uint32_t result = apb_read(top, 0x24);
    const uint64_t selftest_cycles = read_operation_cycles(top);
    if ((status & 0x07u) != 0x02u || result != 0)
        fail("whole-chip SHAKE256 known-answer self-test failed");
    if (selftest_cycles == 0)
        fail("whole-chip operation counter did not run");
    acknowledge_and_clear(top);

    std::array<uint8_t, PQCLEAN_MLKEM768_CLEAN_CRYPTO_PUBLICKEYBYTES> kem_pk{};
    std::array<uint8_t, PQCLEAN_MLKEM768_CLEAN_CRYPTO_SECRETKEYBYTES> kem_dk{};
    std::array<uint8_t, PQCLEAN_MLKEM768_CLEAN_CRYPTO_CIPHERTEXTBYTES> kem_ct{};
    std::array<uint8_t, PQCLEAN_MLKEM768_CLEAN_CRYPTO_BYTES> kem_expected{};
    if (PQCLEAN_MLKEM768_CLEAN_crypto_kem_keypair(kem_pk.data(), kem_dk.data()) != 0 ||
        PQCLEAN_MLKEM768_CLEAN_crypto_kem_enc(
            kem_ct.data(), kem_expected.data(), kem_pk.data()) != 0)
        fail("software oracle could not create an ML-KEM-768 transaction");

    stream_buffer(top, 4, kem_dk.data(), kem_dk.size());
    stream_buffer(top, 5, kem_ct.data(), kem_ct.size());
    launch(top, 2);
    const uint32_t kem_elapsed =
        wait_for_completion(top, 20000000, "ML-KEM-768 decapsulation");
    const uint64_t kem_cycles = read_operation_cycles(top);
    if ((apb_read(top, 0x0c) & 0x07u) != 0x02u ||
        apb_read(top, 0x24) != 0 || apb_read(top, 0x28) != 32)
        fail("whole-chip ML-KEM-768 completion status mismatch");
    const std::array<uint8_t, 32> kem_actual = read_shared_secret(top);
    if (std::memcmp(kem_actual.data(), kem_expected.data(), kem_actual.size()) != 0)
        fail("whole-chip ML-KEM-768 shared secret mismatch");
    acknowledge_and_clear(top);

    static const std::array<uint8_t, 31> message = {
        0x4c, 0x54, 0x50, 0x01, 0x00, 0x00, 0x00, 0x2a,
        0x73, 0x75, 0x77, 0x61, 0x70, 0x70, 0x75, 0x2d,
        0x6c, 0x61, 0x74, 0x74, 0x69, 0x63, 0x65, 0x2d,
        0x62, 0x72, 0x69, 0x64, 0x67, 0x65, 0x00,
    };
    static const std::array<uint8_t, 25> context = {
        's', 'u', 'w', 'a', 'p', 'p', 'u', ':', 'l', 'a', 't', 't', 'i', 'c', 'e',
        '-', 'b', 'r', 'i', 'd', 'g', 'e', ':', 'v', '1',
    };
    std::array<uint8_t, PQCLEAN_MLDSA65_CLEAN_CRYPTO_PUBLICKEYBYTES> dsa_pk{};
    std::array<uint8_t, PQCLEAN_MLDSA65_CLEAN_CRYPTO_SECRETKEYBYTES> dsa_sk{};
    std::array<uint8_t, PQCLEAN_MLDSA65_CLEAN_CRYPTO_BYTES> dsa_sig{};
    size_t signature_length = 0;
    if (PQCLEAN_MLDSA65_CLEAN_crypto_sign_keypair(dsa_pk.data(), dsa_sk.data()) != 0 ||
        PQCLEAN_MLDSA65_CLEAN_crypto_sign_signature_ctx(
            dsa_sig.data(), &signature_length,
            message.data(), message.size(), context.data(), context.size(),
            dsa_sk.data()) != 0 ||
        signature_length != dsa_sig.size())
        fail("software oracle could not create an ML-DSA-65 transaction");

    stream_buffer(top, 0, dsa_pk.data(), dsa_pk.size());
    stream_buffer(top, 1, dsa_sig.data(), dsa_sig.size());
    stream_buffer(top, 2, message.data(), message.size());
    stream_buffer(top, 3, context.data(), context.size());
    launch(top, 1);
    const uint32_t dsa_elapsed =
        wait_for_completion(top, 50000000, "ML-DSA-65 verification");
    const uint64_t dsa_cycles = read_operation_cycles(top);
    if ((apb_read(top, 0x0c) & 0x0fu) != 0x0au ||
        apb_read(top, 0x24) != 0 || apb_read(top, 0x28) != 0)
        fail("whole-chip ML-DSA-65 verification status mismatch");

    std::cout << "PASS: whole-chip firmware/RTL path: self-test=" << selftest_cycles
              << ", ML-KEM-768 decap=" << kem_cycles
              << ", ML-DSA-65 verify=" << dsa_cycles << " busy cycles"
              << " (wall clocks " << selftest_elapsed << "/" << kem_elapsed
              << "/" << dsa_elapsed << ")\n";
    return 0;
}
