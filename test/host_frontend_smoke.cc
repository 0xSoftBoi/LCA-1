// SPDX-License-Identifier: Apache-2.0

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

#include "host_frontend.cc"

using cxxrtl_design::p_lca__host__frontend;

namespace {

[[noreturn]] void fail(const std::string &message) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
}

void tick(p_lca__host__frontend &top) {
    top.p_clk__i.set<uint32_t>(0);
    top.step();
    top.p_clk__i.set<uint32_t>(1);
    top.step();
}

void initialize_inputs(p_lca__host__frontend &top) {
    top.p_clk__i.set<uint32_t>(0);
    top.p_rst__ni.set<uint32_t>(0);
    top.p_zeroize__i.set<uint32_t>(0);
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
    top.p_fw__claim__i.set<uint32_t>(0);
    top.p_fw__result__we__i.set<uint32_t>(0);
    top.p_fw__result__index__i.set<uint32_t>(0);
    top.p_fw__result__data__i.set<uint32_t>(0);
    top.p_fw__complete__i.set<uint32_t>(0);
    top.p_fw__result__code__i.set<uint32_t>(0);
    top.p_fw__result__len__i.set<uint32_t>(0);
    top.p_cycle__count__i.set<uint64_t>(0x1122334455667788ULL);
    top.step();
    tick(top);
    top.p_rst__ni.set<uint32_t>(1);
    top.step();
}

uint32_t apb_read(p_lca__host__frontend &top, uint32_t address) {
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

void apb_write(p_lca__host__frontend &top, uint32_t address,
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

void stream_word(p_lca__host__frontend &top, uint32_t kind,
                 uint32_t word_index, uint32_t total_words,
                 uint32_t base_byte) {
    const uint32_t data = 0xa5000000u ^ (kind << 20) ^ word_index;
    top.p_s__kind__i.set<uint32_t>(kind);
    top.p_s__data__i.set<uint32_t>(data);
    top.p_s__keep__i.set<uint32_t>(0xf);
    top.p_s__last__i.set<uint32_t>(word_index + 1 == total_words);
    top.p_s__valid__i.set<uint32_t>(1);
    top.step();
    if (top.p_s__ready__o.get<uint32_t>() == 0)
        fail("input stream unexpectedly backpressured");
    if (top.p_dma__we__o.get<uint32_t>() == 0)
        fail("accepted stream word did not issue an SRAM write");
    if (top.p_dma__word__addr__o.get<uint32_t>() !=
        ((base_byte >> 2) + word_index))
        fail("stream-to-SRAM address mapping mismatch");
    if (top.p_dma__wdata__o.get<uint32_t>() != data ||
        top.p_dma__wstrb__o.get<uint32_t>() != 0xf)
        fail("stream-to-SRAM data mapping mismatch");
    tick(top);
    top.p_s__valid__i.set<uint32_t>(0);
    top.step();
}

void pulse_fw_claim(p_lca__host__frontend &top) {
    top.p_fw__claim__i.set<uint32_t>(1);
    tick(top);
    top.p_fw__claim__i.set<uint32_t>(0);
    top.step();
}

void write_fw_result(p_lca__host__frontend &top, uint32_t index,
                     uint32_t value) {
    top.p_fw__result__index__i.set<uint32_t>(index);
    top.p_fw__result__data__i.set<uint32_t>(value);
    top.p_fw__result__we__i.set<uint32_t>(1);
    tick(top);
    top.p_fw__result__we__i.set<uint32_t>(0);
    top.step();
}

void complete_fw(p_lca__host__frontend &top, uint32_t code,
                 uint32_t length) {
    top.p_fw__result__code__i.set<uint32_t>(code);
    top.p_fw__result__len__i.set<uint32_t>(length);
    top.p_fw__complete__i.set<uint32_t>(1);
    tick(top);
    top.p_fw__complete__i.set<uint32_t>(0);
    top.step();
}

} // namespace

int main() {
    constexpr uint32_t dk_words = 2400 / 4;
    constexpr uint32_t ct_words = 1088 / 4;
    p_lca__host__frontend top;
    initialize_inputs(top);

    if (apb_read(top, 0x00) != 0x4c434131u)
        fail("chip identity register mismatch");
    if (apb_read(top, 0x04) != 0x00020000u)
        fail("ABI version register mismatch");
    if (apb_read(top, 0x20) != 0x0cu)
        fail("empty message/context defaults are not loaded");
    if (apb_read(top, 0x2c) != 0x55667788u ||
        apb_read(top, 0x30) != 0x11223344u)
        fail("cycle counter register mapping mismatch");

    top.p_s__kind__i.set<uint32_t>(7);
    top.p_s__valid__i.set<uint32_t>(1);
    top.step();
    if (top.p_s__ready__o.get<uint32_t>() != 0 ||
        top.p_dma__we__o.get<uint32_t>() != 0)
        fail("reserved input tag was accepted");
    top.p_s__valid__i.set<uint32_t>(0);

    for (uint32_t i = 0; i < dk_words; ++i)
        stream_word(top, 4, i, dk_words, 0x00071700u);
    for (uint32_t i = 0; i < ct_words; ++i)
        stream_word(top, 5, i, ct_words, 0x00072080u);
    if (apb_read(top, 0x20) != 0x3cu)
        fail("exact ML-KEM inputs were not marked loaded");

    apb_write(top, 0x10, 2); // ML-KEM-768 decapsulation
    apb_write(top, 0x14, 1); // start
    if (top.p_busy__o.get<uint32_t>() == 0 ||
        top.p_command__pending__o.get<uint32_t>() == 0 ||
        top.p_command__o.get<uint32_t>() != 2)
        fail("valid command was not atomically launched");
    if (apb_read(top, 0x28) != 0)
        fail("new command retained a stale result length");

    pulse_fw_claim(top);
    if (top.p_command__pending__o.get<uint32_t>() != 0 ||
        top.p_busy__o.get<uint32_t>() == 0)
        fail("firmware claim changed host-visible command lifetime");

    std::array<uint32_t, 8> result{};
    for (uint32_t i = 0; i < result.size(); ++i) {
        result[i] = 0x5a770000u + i;
        write_fw_result(top, i, result[i]);
    }
    complete_fw(top, 0, 32);
    if (top.p_busy__o.get<uint32_t>() != 0 ||
        top.p_done__o.get<uint32_t>() == 0 ||
        top.p_error__o.get<uint32_t>() != 0 ||
        apb_read(top, 0x28) != 32)
        fail("firmware completion status mismatch");

    top.p_m__ready__i.set<uint32_t>(1);
    for (uint32_t i = 0; i < result.size(); ++i) {
        top.step();
        if (top.p_m__valid__o.get<uint32_t>() == 0 ||
            top.p_m__data__o.get<uint32_t>() != result[i] ||
            top.p_m__keep__o.get<uint32_t>() != 0xf ||
            top.p_m__last__o.get<uint32_t>() != (i == result.size() - 1))
            fail("shared-secret output framing mismatch");
        tick(top);
    }
    top.p_m__ready__i.set<uint32_t>(0);
    top.step();
    if (top.p_m__valid__o.get<uint32_t>() != 0)
        fail("output stream remained active after its final word");

    apb_write(top, 0x14, 2); // acknowledge and scrub result
    if (top.p_done__o.get<uint32_t>() != 0 || apb_read(top, 0x28) != 0)
        fail("completion acknowledgement did not clear metadata");
    for (uint32_t i = 0; i < result.size(); ++i) {
        if (apb_read(top, 0x40 + 4 * i) != 0)
            fail("completion acknowledgement did not scrub result words");
    }

    apb_write(top, 0x14, 4); // clear input metadata
    if (apb_read(top, 0x20) != 0x0cu)
        fail("input clear did not restore empty variable-length objects");

    // A short fixed-size object may write its accepted beat, but it must
    // poison the transaction and fail closed at launch.
    stream_word(top, 4, 0, 1, 0x00071700u);
    apb_write(top, 0x10, 2);
    apb_write(top, 0x14, 1);
    if (top.p_busy__o.get<uint32_t>() != 0 ||
        top.p_done__o.get<uint32_t>() == 0 ||
        top.p_error__o.get<uint32_t>() == 0 ||
        apb_read(top, 0x24) != 0x81u)
        fail("short fixed-size input did not fail closed");

    top.p_zeroize__i.set<uint32_t>(1);
    tick(top);
    top.p_zeroize__i.set<uint32_t>(0);
    top.step();
    if (top.p_busy__o.get<uint32_t>() != 0 ||
        top.p_done__o.get<uint32_t>() != 0 ||
        top.p_error__o.get<uint32_t>() != 0 ||
        apb_read(top, 0x20) != 0x0cu)
        fail("zeroization did not restore the frontend reset state");

    apb_write(top, 0x14, 8); // chip-level scrub request pulse
    if (top.p_zeroize__req__o.get<uint32_t>() == 0)
        fail("host zeroize request was not emitted");
    tick(top);
    if (top.p_zeroize__req__o.get<uint32_t>() != 0)
        fail("host zeroize request was not a single-cycle pulse");

    std::cout << "PASS: APB control, exact-length ingress, mailbox, output, and zeroize\n";
    return 0;
}
