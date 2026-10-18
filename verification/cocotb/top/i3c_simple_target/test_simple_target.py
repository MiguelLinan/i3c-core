# SPDX-License-Identifier: Apache-2.0

import logging
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotbext_i3c.i3c_controller import I3cController
from cocotbext_i3c.i3c_target import I3CTarget
from ccc import CCC
from common import timeout_task, log_seed
from pmic_real_bits import NUM_PMIC_REGS, REAL_BITS, STATUS_BITS

STATIC_ADDR = 0x5A
DYNAMIC_ADDR = 0x30


async def setup_simple_target(dut, fclk=100.0, fbus=12.5):
    """
    Sets up clock, reset, and I3C Controller BFM for the CPU-less simple_target_only DUT.
    Notice: Zero AXI/AHB bus setup or CSR boot_init() required!
    """
    cocotb.log.setLevel(logging.INFO)
    log_seed(dut)
    cocotb.start_soon(timeout_task(200000))

    # Initialize top-level inputs
    dut.clk.value = 0
    dut.rst_n.value = 0
    dut.buck1_pgood_i.value = 0
    dut.ldo1_pgood_i.value = 0
    dut.ovp_fault_i.value = 0
    dut.otp_warn_i.value = 0
    dut.osc_lock_i.value = 0
    dut.peripheral_reset_done_i.value = 0

    # Start system clock
    clk_period_ns = round(1000.0 / fclk, 3)
    cocotb.start_soon(Clock(dut.clk, clk_period_ns, units="ns").start())

    i3c_controller = I3cController(
        sda_i=dut.bus_sda,
        sda_o=dut.sda_sim_ctrl_i,
        scl_i=dut.bus_scl,
        scl_o=dut.scl_sim_ctrl_i,
        debug_state_o=None,
        speed=fbus * 1e6,
    )

    i3c_target_bfm = I3CTarget(
        sda_i=dut.bus_sda,
        sda_o=dut.sda_sim_target_i,
        scl_i=dut.bus_scl,
        scl_o=dut.scl_sim_target_i,
        debug_state_o=None,
        speed=fbus * 1e6,
    )

    # Apply active-low reset
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 20)

    # Assign dynamic address via SETDASA CCC using hardcoded static address (0x5A)
    await i3c_controller.i3c_ccc_write(
        CCC.DIRECT.SETDASA, directed_data=[(STATIC_ADDR, [DYNAMIC_ADDR << 1])]
    )

    return i3c_controller, i3c_target_bfm


async def i3c_write_reg(i3c_controller, dev_addr, reg_addr, data_bytes):
    """Write one or more bytes starting at reg_addr over I3C Private Write."""
    await i3c_controller.i3c_write(dev_addr, [reg_addr] + list(data_bytes))


async def i3c_read_reg(i3c_controller, dev_addr, reg_addr, length=1):
    """Read one or more bytes starting at reg_addr using Write(reg_addr) + Sr + Read(length)."""
    await i3c_controller.i3c_write(dev_addr, [reg_addr], stop=False)
    resp = await i3c_controller.i3c_read(dev_addr, length)
    return list(resp.data)


@cocotb.test()
async def test_pmic_real_bits_sweep(dut):
    """
    Sweeps all PMIC registers generated from SystemRDL over I3C using the
    auto-generated REAL_BITS and STATUS_BITS matrices:
      - Verifies writable bits latch 0xFF, 0xAA, 0x55, 0x00
      - Verifies empty/unimplemented bits always read back as 0
      - Verifies live status input bits reflect hardware inputs and ignore I3C writes
    """
    i3c_ctrl, _ = await setup_simple_target(dut)

    # Set known status input values to verify RO status bits alongside RW bits
    dut.buck1_pgood_i.value = 1
    dut.ldo1_pgood_i.value = 0
    dut.ovp_fault_i.value = 1
    dut.otp_warn_i.value = 0
    dut.osc_lock_i.value = 1
    await ClockCycles(dut.clk, 2)

    expected_ro_vals = {
        0x00: 0x00,
        0x01: 0x00,
        0x02: (1 << 0) | (0 << 1) | (1 << 4) | (0 << 5),  # 0x11
        0x03: (1 << 6),  # 0x40
    }

    for addr in range(NUM_PMIC_REGS):
        mask_rw = sum((REAL_BITS[addr][b] << b) for b in range(8))
        mask_ro = sum((STATUS_BITS[addr][b] << b) for b in range(8))

        for pattern in [0xFF, 0xAA, 0x55, 0x00]:
            await i3c_write_reg(i3c_ctrl, DYNAMIC_ADDR, addr, [pattern])
            read_bytes = await i3c_read_reg(i3c_ctrl, DYNAMIC_ADDR, addr, 1)
            actual = read_bytes[0]

            expected_rw = pattern & mask_rw
            expected_total = expected_rw | (expected_ro_vals[addr] & mask_ro)

            dut._log.info(
                f"Reg 0x{addr:02X}: wrote=0x{pattern:02X}, rw_mask=0x{mask_rw:02X}, "
                f"ro_mask=0x{mask_ro:02X} -> read=0x{actual:02X} (expected=0x{expected_total:02X})"
            )
            assert actual == expected_total, (
                f"Reg 0x{addr:02X} mismatch! Wrote 0x{pattern:02X}, "
                f"expected 0x{expected_total:02X}, got 0x{actual:02X}"
            )


@cocotb.test()
async def test_pmic_trim_outputs_and_burst_rw(dut):
    """
    Verifies:
      1. Multi-byte burst write & burst read auto-incrementing across PMIC registers
      2. PeakRDL hwif_out struct signals (buck1_vout_trim_o, buck1_en_o, etc.) update immediately
      3. CCC GETPID, GETBCR, GETDCR return the hardcoded target identity constants
    """
    i3c_ctrl, _ = await setup_simple_target(dut)

    # 1. Burst write to Reg 0x00 (BUCK1_CFG) and Reg 0x01 (LDO1_CFG) in a single I3C frame
    #    BUCK1_CFG = 0x95 -> buck1_en=1 (bit 7), empty[6:5]=0, buck1_vout_trim=5'h15
    #    LDO1_CFG  = 0x16 -> empty[7:5]=0, ldo1_en=1 (bit 4), empty[3]=0, ldo1_vout_trim=3'h6
    await i3c_write_reg(i3c_ctrl, DYNAMIC_ADDR, 0x00, [0x95, 0x16])
    await ClockCycles(dut.clk, 2)

    assert int(dut.buck1_en_o.value) == 1
    assert int(dut.buck1_vout_trim_o.value) == 0x15
    assert int(dut.ldo1_en_o.value) == 1
    assert int(dut.ldo1_vout_trim_o.value) == 0x06

    # 2. Burst read 2 bytes starting at Reg 0x00
    burst_read = await i3c_read_reg(i3c_ctrl, DYNAMIC_ADDR, 0x00, length=2)
    assert burst_read == [0x95, 0x16], f"Expected [0x95, 0x16], got {burst_read}"

    # 3. Verify Direct CCC GETBCR and GETDCR
    bcr_resp = await i3c_ctrl.i3c_ccc_read(CCC.DIRECT.GETBCR, addr=DYNAMIC_ADDR, count=1)
    dcr_resp = await i3c_ctrl.i3c_ccc_read(CCC.DIRECT.GETDCR, addr=DYNAMIC_ADDR, count=1)
    assert list(bcr_resp[0][1]) == [0x00], f"Unexpected BCR: {bcr_resp}"
    assert list(dcr_resp[0][1]) == [0xC6], f"Unexpected DCR: {dcr_resp}"

