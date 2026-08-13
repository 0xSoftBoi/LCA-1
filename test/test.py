import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


Q_MLKEM = 3_329
Q_MLDSA = 8_380_417


async def cycle(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def write8(dut, address, value):
    dut.ui_in.value = value & 0xFF
    dut.uio_in.value = (address & 0xF) | 0x10
    await cycle(dut)
    dut.uio_in.value = address & 0xF
    await Timer(1, unit="ns")


async def read8(dut, address):
    dut.uio_in.value = address & 0xF
    await Timer(1, unit="ns")
    return int(dut.uo_out.value)


async def write24(dut, address, value):
    await write8(dut, address + 0, value >> 0)
    await write8(dut, address + 1, value >> 8)
    await write8(dut, address + 2, value >> 16)


async def read24(dut, address):
    return (
        await read8(dut, address + 0)
        | (await read8(dut, address + 1)) << 8
        | (await read8(dut, address + 2)) << 16
    )


async def wait_done(dut, require_busy=True):
    saw_busy = False
    for _ in range(50):
        status = int(dut.uio_out.value)
        saw_busy |= bool(status & 0x20)
        if status & 0x40:
            assert saw_busy or not require_busy
            return status
        await cycle(dut)
    raise AssertionError("timeout waiting for done")


async def run_command(dut, mode_kem, op, a, b, zeta=0):
    await write24(dut, 0x1, a)
    await write24(dut, 0x4, b)
    await write24(dut, 0x7, zeta)
    await write8(dut, 0x0, 0x80 | (op << 1) | int(mode_kem))
    status = await wait_done(dut, require_busy=op != 3 and a < (Q_MLKEM if mode_kem else Q_MLDSA))
    return status, await read24(dut, 0xA), await read24(dut, 0xD)


@cocotb.test()
async def test_lca1_bus_and_arithmetic(dut):
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    for _ in range(4):
        await cycle(dut)
    dut.rst_n.value = 1
    await cycle(dut)

    assert int(dut.uio_oe.value) == 0xE0
    assert await read8(dut, 0x0) == 0x90

    for mode_kem, q in ((True, Q_MLKEM), (False, Q_MLDSA)):
        a, b, zeta = q - 17, q - 29, q - 43

        status, out0, out1 = await run_command(dut, mode_kem, 0, a, b, zeta)
        assert not status & 0x80
        assert (out0, out1) == ((a * b) % q, 0)

        t = (zeta * b) % q
        status, out0, out1 = await run_command(dut, mode_kem, 1, a, b, zeta)
        assert not status & 0x80
        assert (out0, out1) == ((a + t) % q, (a - t) % q)

        status, out0, out1 = await run_command(dut, mode_kem, 2, a, b, zeta)
        assert not status & 0x80
        assert (out0, out1) == ((a + b) % q, (zeta * ((a - b) % q)) % q)

    # The start transaction atomically captures operands.
    a, b = 123, 456
    await write24(dut, 0x1, a)
    await write24(dut, 0x4, b)
    await write24(dut, 0x7, 0)
    await write8(dut, 0x0, 0x81)
    await write24(dut, 0x1, 0x654321)
    await write24(dut, 0x4, 0x123456)
    status = await wait_done(dut)
    assert not status & 0x80
    assert await read24(dut, 0xA) == (a * b) % Q_MLKEM

    # Reserved opcode must complete with error and zero outputs.
    status, out0, out1 = await run_command(dut, False, 3, 0, 0, 0)
    assert status & 0x80
    assert (out0, out1) == (0, 0)
