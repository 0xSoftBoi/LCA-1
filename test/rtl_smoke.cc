#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

#include "tt_lca.cc"

using cxxrtl_design::p_tt__um__suwappu__lattice__accel;

namespace {

constexpr uint32_t Q_MLKEM = 3329;
constexpr uint32_t Q_MLDSA = 8380417;

uint32_t rng_state = 0x4c434131u;  // "LCA1"

uint32_t next_random() {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

void fail(const std::string &message) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
}

uint32_t modmul(uint32_t a, uint32_t b, uint32_t q) {
    return static_cast<uint32_t>((static_cast<uint64_t>(a) * b) % q);
}

void tick(p_tt__um__suwappu__lattice__accel &top) {
    top.p_clk.set<uint32_t>(0);
    top.step();
    top.p_clk.set<uint32_t>(1);
    top.step();
}

void reset(p_tt__um__suwappu__lattice__accel &top) {
    top.p_clk.set<uint32_t>(0);
    top.p_rst__n.set<uint32_t>(0);
    top.p_ena.set<uint32_t>(1);
    top.p_ui__in.set<uint32_t>(0);
    top.p_uio__in.set<uint32_t>(0);
    top.step();
    tick(top);
    top.p_rst__n.set<uint32_t>(1);
    top.step();
}

void write8(p_tt__um__suwappu__lattice__accel &top, uint32_t address, uint32_t value) {
    top.p_ui__in.set<uint32_t>(value & 0xffu);
    top.p_uio__in.set<uint32_t>((address & 0xfu) | 0x10u);
    tick(top);
    top.p_uio__in.set<uint32_t>(address & 0xfu);
    top.step();
}

uint32_t read8(p_tt__um__suwappu__lattice__accel &top, uint32_t address) {
    top.p_uio__in.set<uint32_t>(address & 0xfu);
    top.step();
    return top.p_uo__out.get<uint32_t>();
}

void write24(p_tt__um__suwappu__lattice__accel &top, uint32_t address, uint32_t value) {
    write8(top, address + 0, value >> 0);
    write8(top, address + 1, value >> 8);
    write8(top, address + 2, value >> 16);
}

uint32_t read24(p_tt__um__suwappu__lattice__accel &top, uint32_t address) {
    return read8(top, address + 0) |
           (read8(top, address + 1) << 8) |
           (read8(top, address + 2) << 16);
}

unsigned command(p_tt__um__suwappu__lattice__accel &top,
                 bool mode_kem, uint32_t op,
                 uint32_t a, uint32_t b, uint32_t zeta,
                 uint32_t expected0, uint32_t expected1,
                 bool expect_error = false,
                 bool overwrite_after_start = false) {
    write24(top, 0x1, a);
    write24(top, 0x4, b);
    write24(top, 0x7, zeta);

    if (read24(top, 0x1) != a || read24(top, 0x4) != b || read24(top, 0x7) != zeta)
        fail("register write/read round-trip mismatch");

    write8(top, 0x0, 0x80u | ((op & 3u) << 1) | (mode_kem ? 1u : 0u));

    if (overwrite_after_start) {
        // These writes overlap the launch window. The active command must use
        // the values atomically captured by the preceding start transaction.
        write24(top, 0x1, 0x654321u);
        write24(top, 0x4, 0x123456u);
        write24(top, 0x7, 0xabcdefu);
    }

    bool saw_busy = false;
    for (unsigned cycle = 1; cycle <= 50; ++cycle) {
        const uint32_t status = top.p_uio__out.get<uint32_t>();
        saw_busy = saw_busy || ((status & 0x20u) != 0);
        if ((status & 0x40u) != 0) {
            if (((status & 0x80u) != 0) != expect_error)
                fail("error status mismatch");
            if (!expect_error) {
                if (!saw_busy)
                    fail("busy was never observed");
                if (read24(top, 0xA) != expected0 || read24(top, 0xD) != expected1)
                    fail("result register mismatch");
            }
            return cycle;
        }
        tick(top);
    }
    fail("timeout waiting for latched done status");
    return 0;
}

void test_mode(p_tt__um__suwappu__lattice__accel &top, bool mode_kem) {
    const uint32_t q = mode_kem ? Q_MLKEM : Q_MLDSA;
    const char *name = mode_kem ? "ML-KEM-768" : "ML-DSA-65";
    unsigned latency[3] = {0, 0, 0};

    for (unsigned i = 0; i < 64; ++i) {
        const uint32_t a = next_random() % q;
        const uint32_t b = next_random() % q;
        const uint32_t zeta = next_random() % q;

        const uint32_t expected_mul = modmul(a, b, q);
        const unsigned mul_cycles = command(top, mode_kem, 0, a, b, zeta, expected_mul, 0);

        const uint32_t t = modmul(zeta, b, q);
        const uint32_t ct0 = static_cast<uint32_t>((static_cast<uint64_t>(a) + t) % q);
        const uint32_t ct1 = a >= t ? a - t : q - (t - a);
        const unsigned ct_cycles = command(top, mode_kem, 1, a, b, zeta, ct0, ct1);

        const uint32_t gs0 = static_cast<uint32_t>((static_cast<uint64_t>(a) + b) % q);
        const uint32_t diff = a >= b ? a - b : q - (b - a);
        const uint32_t gs1 = modmul(zeta, diff, q);
        const unsigned gs_cycles = command(top, mode_kem, 2, a, b, zeta, gs0, gs1);

        const unsigned observed[3] = {mul_cycles, ct_cycles, gs_cycles};
        for (unsigned op = 0; op < 3; ++op) {
            if (latency[op] == 0)
                latency[op] = observed[op];
            if (latency[op] != observed[op])
                fail(std::string(name) + " command latency changed with operand values");
        }
    }

    command(top, mode_kem, 0, q, 1, 0, 0, 0, true);
    command(top, mode_kem, 3, 0, 0, 0, 0, 0, true);

    const uint32_t a = q - 17;
    const uint32_t b = q - 29;
    command(top, mode_kem, 0, a, b, 0, modmul(a, b, q), 0, false, true);

    std::cout << name << " wrapper latency: mul=" << latency[0]
              << ", CT=" << latency[1] << ", GS=" << latency[2]
              << " cycles\n";
}

void test_rejects_overlapping_start(p_tt__um__suwappu__lattice__accel &top) {
    const uint32_t a = 100;
    const uint32_t b = 200;
    write24(top, 0x1, a);
    write24(top, 0x4, b);
    write24(top, 0x7, 0);
    write8(top, 0x0, 0x81u);  // ML-KEM modular multiply.

    for (unsigned cycle = 0; cycle < 8; ++cycle) {
        if ((top.p_uio__out.get<uint32_t>() & 0x20u) != 0)
            break;
        tick(top);
    }
    if ((top.p_uio__out.get<uint32_t>() & 0x20u) == 0)
        fail("core did not enter busy state");

    write8(top, 0x0, 0x81u);
    if ((top.p_uio__out.get<uint32_t>() & 0x80u) == 0)
        fail("overlapping start was not rejected");

    for (unsigned cycle = 0; cycle < 50; ++cycle) {
        if ((top.p_uio__out.get<uint32_t>() & 0x40u) != 0) {
            if ((top.p_uio__out.get<uint32_t>() & 0x80u) == 0)
                fail("overlapping-start error did not remain latched");
            if (read24(top, 0xA) != modmul(a, b, Q_MLKEM))
                fail("rejected start corrupted active command");
            return;
        }
        tick(top);
    }
    fail("active command did not finish after overlapping-start rejection");
}

}  // namespace

int main() {
    p_tt__um__suwappu__lattice__accel top;
    reset(top);

    if (top.p_uio__oe.get<uint32_t>() != 0xe0u)
        fail("uio output-enable mask mismatch");
    if (read8(top, 0x0) != 0x90u)
        fail("identity/control reset value mismatch");

    test_mode(top, true);
    test_mode(top, false);
    test_rejects_overlapping_start(top);

    std::cout << "PASS: 387 valid RTL operations plus atomic capture and rejection/error paths\n";
    return 0;
}
