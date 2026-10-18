// SPDX-License-Identifier: Apache-2.0
`include "i3c_defines.svh"

module i3c_test_wrapper #(
    parameter bit ControllerEn = 0,  // UNUSED
    parameter bit TargetEn = 1,  // UNUSED
`ifdef I3C_USE_AHB
    parameter int unsigned AhbDataWidth = `AHB_DATA_WIDTH,
    parameter int unsigned AhbAddrWidth = `AHB_ADDR_WIDTH
`elsif I3C_USE_AXI
    parameter int unsigned AxiDataWidth = `AXI_DATA_WIDTH,
    parameter int unsigned AxiAddrWidth = `AXI_ADDR_WIDTH,
    parameter int unsigned AxiUserWidth = `AXI_USER_WIDTH,
    parameter int unsigned AxiIdWidth = `AXI_ID_WIDTH,
`ifdef AXI_ID_FILTERING
    parameter int unsigned NumPrivIds = `NUM_PRIV_IDS
`endif
`elsif I3C_USE_SIMPLE
    parameter int unsigned SimpleAddrWidth = `SIMPLE_ADDR_WIDTH,
    parameter int unsigned SimpleDataWidth = `SIMPLE_DATA_WIDTH
`endif
) (
`ifdef I3C_USE_AHB
    input  logic                      hclk,
    input  logic                      hreset_n,
    // AHB-Lite interface
    input  logic [  AhbAddrWidth-1:0] haddr,
    input  logic [               2:0] hburst,
    input  logic [               3:0] hprot,
    input  logic [               2:0] hsize,
    input  logic [               1:0] htrans,
    input  logic [  AhbDataWidth-1:0] hwdata,
    input  logic [AhbDataWidth/8-1:0] hwstrb,
    input  logic                      hwrite,
    output logic [  AhbDataWidth-1:0] hrdata,
    output logic                      hreadyout,
    output logic                      hresp,
    input  logic                      hsel,
    input  logic                      hready,
`elsif I3C_USE_AXI
    input  logic                      aclk,
    input  logic                      areset_n,
    // AXI4 Interface
    // AXI Read Channels
    input  logic [  AxiAddrWidth-1:0] araddr,
    input  logic [               1:0] arburst,
    input  logic [               2:0] arsize,
    input  logic [               7:0] arlen,
    input  logic [  AxiUserWidth-1:0] aruser,
    input  logic [    AxiIdWidth-1:0] arid,
    input  logic                      arlock,
    input  logic                      arvalid,
    output logic                      arready,

    output logic [AxiDataWidth-1:0] rdata,
    output logic [             1:0] rresp,
    output logic [  AxiIdWidth-1:0] rid,
    output logic                    rlast,
    output logic                    rvalid,
    input  logic                    rready,

    // AXI Write Channels
    input  logic [AxiAddrWidth-1:0] awaddr,
    input  logic [             1:0] awburst,
    input  logic [             2:0] awsize,
    input  logic [             7:0] awlen,
    input  logic [AxiUserWidth-1:0] awuser,
    input  logic [  AxiIdWidth-1:0] awid,
    input  logic                    awlock,
    input  logic                    awvalid,
    output logic                    awready,

    input  logic [  AxiDataWidth-1:0] wdata,
    input  logic [AxiDataWidth/8-1:0] wstrb,
    input  logic [  AxiUserWidth-1:0] wuser,
    input  logic                      wlast,
    input  logic                      wvalid,
    output logic                      wready,

    output logic [           1:0] bresp,
    output logic [AxiIdWidth-1:0] bid,
    output logic                  bvalid,
    input  logic                  bready,

`ifdef AXI_ID_FILTERING
    input logic disable_id_filtering_i,
    input logic [AxiUserWidth-1:0] priv_ids_i[NumPrivIds],
`endif
`elsif I3C_USE_SIMPLE
    input  logic clk,
    input  logic rst_n,

    // PMIC Status inputs (packed into hwif_in for PeakRDL pmic_regbank)
    input  logic buck1_pgood_i,
    input  logic ldo1_pgood_i,
    input  logic ovp_fault_i,
    input  logic otp_warn_i,
    input  logic osc_lock_i,

    // PMIC Programming / Trimming outputs (unpacked from hwif_out of PeakRDL pmic_regbank)
    output logic [4:0] buck1_vout_trim_o,
    output logic       buck1_en_o,
    output logic [2:0] ldo1_vout_trim_o,
    output logic       ldo1_en_o,
    output logic [3:0] osc_trim_o,
`endif
    // I3C Target Simulation model
    input logic sda_sim_target_i,
    input logic scl_sim_target_i,
    input wire [4:0] debug_state_controller_i,

    // I3C Target Controller model
    input logic sda_sim_ctrl_i,
    input logic scl_sim_ctrl_i,
    input wire [4:0] debug_state_target_i,
    input wire [3:0] debug_detected_header_i,

    // I3C Bus signals
    output logic bus_sda,
    output logic bus_scl,

    // I3C Core DUT SDA signals (exposed for bus monitor)
    output logic i3c_sda_o,
    output logic i3c_sda_oe,
    output logic i3c_sel_od_pp,

    output logic peripheral_reset_o,
    input  logic peripheral_reset_done_i,
    output logic escalated_reset_o
);

  logic clk_i;
  logic rst_ni;

`ifdef I3C_USE_AHB
  assign clk_i  = hclk;
  assign rst_ni = hreset_n;
`elsif I3C_USE_AXI
  assign clk_i  = aclk;
  assign rst_ni = areset_n;
`elsif I3C_USE_SIMPLE
  assign clk_i  = clk;
  assign rst_ni = rst_n;

  logic [SimpleAddrWidth-1:0] reg_addr;
  logic [SimpleDataWidth-1:0] reg_wdata;
  logic                       reg_we;
  logic                       reg_re;
  logic [SimpleDataWidth-1:0] reg_rdata;

  pmic_regbank_pkg::pmic_regbank__in_t  pmic_hwif_in;
  pmic_regbank_pkg::pmic_regbank__out_t pmic_hwif_out;

  assign pmic_hwif_in.rst_ni                        = rst_ni;
  assign pmic_hwif_in.PMIC_STATUS.buck1_pgood.next  = buck1_pgood_i;
  assign pmic_hwif_in.PMIC_STATUS.ldo1_pgood.next   = ldo1_pgood_i;
  assign pmic_hwif_in.PMIC_STATUS.ovp_fault.next    = ovp_fault_i;
  assign pmic_hwif_in.PMIC_STATUS.otp_warn.next     = otp_warn_i;
  assign pmic_hwif_in.OSC_AND_STAT.osc_lock.next    = osc_lock_i;

  assign buck1_vout_trim_o = pmic_hwif_out.BUCK1_CFG.buck1_vout_trim.value;
  assign buck1_en_o        = pmic_hwif_out.BUCK1_CFG.buck1_en.value;
  assign ldo1_vout_trim_o  = pmic_hwif_out.LDO1_CFG.ldo1_vout_trim.value;
  assign ldo1_en_o         = pmic_hwif_out.LDO1_CFG.ldo1_en.value;
  assign osc_trim_o        = pmic_hwif_out.OSC_AND_STAT.osc_trim.value;

  pmic_regbank u_pmic_regbank (
      .clk        (clk_i),
      .rst        (~rst_ni),
      .reg_addr_i (reg_addr),
      .reg_wdata_i(reg_wdata),
      .reg_we_i   (reg_we),
      .reg_re_i   (reg_re),
      .reg_rdata_o(reg_rdata),
      .hwif_in    (pmic_hwif_in),
      .hwif_out   (pmic_hwif_out)
  );
`endif

  localparam int unsigned NumDevices = 3;  // 2 BFMs (Controller, Target), 1 DUT (I3C Core)

  // SDA/SCL data signals per device
  logic [NumDevices-1:0] sda_data;
  logic [NumDevices-1:0] scl_data;

  // SDA/SCL output enable signals per device
  logic [NumDevices-1:0] sda_oe;
  logic [NumDevices-1:0] scl_oe;

  // OD/PP mode per device
  logic [NumDevices-1:0] sel_od_pp;

  // Device 0: Controller BFM (simulation model, always OD mode)
  // BFMs don't have explicit OE, so derive it: in OD mode, driving when output is 0
  assign sda_data[0]  = sda_sim_ctrl_i;
  assign scl_data[0]  = scl_sim_ctrl_i;
  assign sda_oe[0]    = !sda_sim_ctrl_i;  // OD: driving low when sda=0
  assign scl_oe[0]    = !scl_sim_ctrl_i;  // OD: driving low when scl=0
  assign sel_od_pp[0] = 1'b0;  // Controller BFM always OD

  // Device 1: Target BFM (simulation model, always OD mode)
  assign sda_data[1]  = sda_sim_target_i;
  assign scl_data[1]  = scl_sim_target_i;
  assign sda_oe[1]    = !sda_sim_target_i;  // OD: driving low when sda=0
  assign scl_oe[1]    = !scl_sim_target_i;  // OD: driving low when scl=0
  assign sel_od_pp[1] = 1'b0;  // Target BFM always OD

  // Device 2: I3C Core DUT (has proper OE and OD/PP mode signals)
  // sda_data[2], scl_data[2], sda_oe[2], sel_od_pp[2] connected below from i3c_wrapper

  // I3C Core output signals (i3c_sda_o, i3c_sda_oe, i3c_sel_od_pp are module ports)
  logic i3c_scl_o;
  logic i3c_scl_oe;

  assign sda_data[2]  = i3c_sda_o;
  assign scl_data[2]  = i3c_scl_o;
  assign sda_oe[2]    = i3c_sda_oe;
  assign scl_oe[2]    = !i3c_scl_o;  // SCL from core is OD (driving when low)
  assign sel_od_pp[2] = i3c_sel_od_pp;

  i3c_bus_harness #(
      .NumDevices(NumDevices)
  ) xi3_bus_harness (
      .sda_i      (sda_data),
      .sda_oe_i   (sda_oe),
      .sel_od_pp_i(sel_od_pp),
      .scl_i      (scl_data),
      .scl_oe_i   (scl_oe),
      .sda_o      (bus_sda),
      .scl_o      (bus_scl)
  );

  i3c_wrapper xi3c_wrapper (
      .clk_i,
      .rst_ni,

`ifdef I3C_USE_AHB
      .haddr_i(haddr),
      .hburst_i(hburst),
      .hprot_i(hprot),
      .hsize_i(hsize),
      .htrans_i(htrans),
      .hwdata_i(hwdata),
      .hwstrb_i(hwstrb),
      .hwrite_i(hwrite),
      .hrdata_o(hrdata),
      .hreadyout_o(hreadyout),
      .hresp_o(hresp),
      .hsel_i(hsel),
      .hready_i(hready),
`elsif I3C_USE_AXI
      .araddr_i(araddr),
      .arburst_i(arburst),
      .arsize_i(arsize),
      .arlen_i(arlen),
      .aruser_i(aruser),
      .arid_i(arid),
      .arlock_i(arlock),
      .arvalid_i(arvalid),
      .arready_o(arready),

      .rdata_o(rdata),
      .rresp_o(rresp),
      .rid_o(rid),
      .rlast_o(rlast),
      .rvalid_o(rvalid),
      .rready_i(rready),
      .ruser_o(),

      .awaddr_i(awaddr),
      .awburst_i(awburst),
      .awsize_i(awsize),
      .awlen_i(awlen),
      .awuser_i(awuser),
      .awid_i(awid),
      .awlock_i(awlock),
      .awvalid_i(awvalid),
      .awready_o(awready),

      .wdata_i (wdata),
      .wstrb_i (wstrb),
      .wlast_i (wlast),
      .wvalid_i(wvalid),
      .wready_o(wready),
      .wuser_i (wuser),

      .bresp_o(bresp),
      .bid_o(bid),
      .bvalid_o(bvalid),
      .bready_i(bready),
      .buser_o(),

`ifdef AXI_ID_FILTERING
      .disable_id_filtering_i(disable_id_filtering_i),
      .priv_ids_i(priv_ids_i),
`endif
`elsif I3C_USE_SIMPLE
      .reg_addr_o (reg_addr),
      .reg_wdata_o(reg_wdata),
      .reg_we_o   (reg_we),
      .reg_re_o   (reg_re),
      .reg_rdata_i(reg_rdata),
`endif

      .scl_i(bus_scl),
      .sda_i(bus_sda),
      .scl_o(i3c_scl_o),
      .sda_o(i3c_sda_o),
      .scl_oe(i3c_scl_oe),
      .sda_oe(i3c_sda_oe),
      .sel_od_pp_o(i3c_sel_od_pp),

      .recovery_payload_available_o(),
      .recovery_image_activated_o  (),

      .peripheral_reset_o,
      .peripheral_reset_done_i,
      .escalated_reset_o,

      .irq_o()
  );

endmodule
