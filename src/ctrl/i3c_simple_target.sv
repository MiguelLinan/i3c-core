// SPDX-License-Identifier: Apache-2.0

/*
  Zero-FIFO, CPU-less I3C Target with Direct Register Bank Interface.

  Connects the I3C wire protocol layer (bus_monitor, bus_tx_flow, bus_rx_flow,
  i3c_target_fsm, ccc) directly to a simple hardware register bank:
    - reg_addr_o  [RegAddrWidth-1:0]
    - reg_wdata_o [RegDataWidth-1:0]
    - reg_we_o
    - reg_re_o
    - reg_rdata_i [RegDataWidth-1:0] (supports 1-cycle registered read after reg_re_o)
*/

module i3c_simple_target
  import controller_pkg::*;
  import i3c_pkg::*;
#(
    parameter int unsigned RegAddrWidth    = 8,
    parameter int unsigned RegDataWidth    = 8,
    parameter logic [6:0]  StaticAddr      = 7'h5A,
    parameter bit          StaticAddrValid = 1'b1,
    parameter logic [47:0] ProvisionedId   = 48'h0123_4567_89AB,
    parameter logic [7:0]  Bcr             = 8'h00,  // Bits[7:6]=2'b00 (I3C Target)
    parameter logic [7:0]  Dcr             = 8'hC6   // PMIC / generic device class
) (
    input  logic clk_i,
    input  logic rst_ni,

    // I3C PHY interface
    input  logic scl_i,
    input  logic sda_i,
    output logic scl_o,
    output logic sda_o,
    output logic sda_oe_o,
    output logic sel_od_pp_o,
    input  logic arbitration_lost_i,
    output logic bus_scl_posedge_o,

    // Simple Register Bank Interface
    output logic [RegAddrWidth-1:0] reg_addr_o,
    output logic [RegDataWidth-1:0] reg_wdata_o,
    output logic                    reg_we_o,
    output logic                    reg_re_o,
    input  logic [RegDataWidth-1:0] reg_rdata_i,

    // Target Reset Action signals
    output logic peripheral_reset_o,
    input  logic peripheral_reset_done_i,
    output logic escalated_reset_o
);

  // ===========================================================================
  // 1. Lightweight CCC / Device Identity State (replaces 10k-line target_I3CCSR)
  // ===========================================================================
  i3c_addr_t   target_dyn_addr_q;
  logic        target_dyn_addr_valid_q;

  logic [15:0] mwl_q;
  logic [15:0] mrl_q;
  logic [ 7:0] ibil_q;
  logic        ibi_enable_q;

  // Signals from CCC engine
  logic        set_dasa_valid;
  logic        set_dasa_virtual_device;
  i3c_addr_t   set_dasa;
  logic        set_aasa;
  logic        set_aasa_virt;
  logic        set_newda;
  logic        set_newda_virtual_device;
  i3c_addr_t   newda;
  logic        rstdaa;

  logic        set_mwl;
  logic [15:0] mwl_from_ccc;
  logic        set_mrl;
  logic [15:0] mrl_from_ccc;
  logic        set_ibil;
  logic [ 7:0] ibil_from_ccc;

  logic        enec_ibi, disec_ibi;
  logic        enec_crr, disec_crr;
  logic        enec_hj,  disec_hj;

  logic        rst_action_valid;
  logic [ 7:0] rst_action;
  logic        get_status_done;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      target_dyn_addr_q       <= 7'h00;
      target_dyn_addr_valid_q <= 1'b0;
      mwl_q                   <= 16'h0100;
      mrl_q                   <= 16'h0100;
      ibil_q                  <= 8'h04;
      ibi_enable_q            <= 1'b0;
    end else begin
      // Dynamic Address updates via RSTDAA, SETDASA, ENTDAA, SETNEWDA, SETAASA
      if (rstdaa) begin
        target_dyn_addr_valid_q <= 1'b0;
        target_dyn_addr_q       <= 7'h00;
      end else if (set_dasa_valid && !set_dasa_virtual_device) begin
        target_dyn_addr_valid_q <= 1'b1;
        target_dyn_addr_q       <= set_dasa;
      end else if (set_newda && !set_newda_virtual_device) begin
        target_dyn_addr_valid_q <= 1'b1;
        target_dyn_addr_q       <= newda;
      end else if (set_aasa && StaticAddrValid) begin
        target_dyn_addr_valid_q <= 1'b1;
        target_dyn_addr_q       <= StaticAddr;
      end

      // Max Write/Read/IBI Length updates via SETMWL / SETMRL
      if (set_mwl)  mwl_q  <= mwl_from_ccc;
      if (set_mrl)  mrl_q  <= mrl_from_ccc;
      if (set_ibil) ibil_q <= ibil_from_ccc;

      // Event Enable / Disable (ENEC / DISEC)
      if (enec_ibi)       ibi_enable_q <= 1'b1;
      else if (disec_ibi) ibi_enable_q <= 1'b0;
    end
  end

  // ===========================================================================
  // 2. Bus Monitor & Timers
  // ===========================================================================
  bus_state_t ctrl_bus;
  bus_state_t hdr_exit_bus;
  logic       in_hdr_mode;
  logic       in_hdr_err_mode;
  logic       hdr_exit_detect;
  logic       target_reset_detect;

  bus_monitor xbus_monitor (
      .clk_i,
      .rst_ni,
      .sda_i,
      .scl_i,
      .enable_i        (1'b1),
      .t_hd_dat_i      ('0),
      .t_r_i           ('0),
      .t_f_i           ('0),
      .in_hdr_mode_i   (in_hdr_mode),
      .state_o         (ctrl_bus),
      .hdr_exit_state_o(hdr_exit_bus)
  );

  assign bus_scl_posedge_o = ctrl_bus.scl.pos_edge;
  assign scl_o             = 1'b1;

  i3c_bus_monitor xi3c_bus_monitor (
      .clk_i,
      .rst_ni,
      .enable_i             (1'b1),
      .bus_i                (hdr_exit_bus),
      .is_in_hdr_mode_i     (in_hdr_mode),
      .is_in_hdr_err_mode_i (in_hdr_err_mode),
      .hdr_timeout_en_i     (1'b0),
      .t_hdr_timeout_i      ('0),
      .hdr_exit_detect_o    (hdr_exit_detect),
      .target_reset_detect_o(target_reset_detect)
  );

  logic bus_busy, bus_free, bus_idle, bus_available;

  bus_timers xbus_timers (
      .clk_i,
      .rst_ni,
      .enable_i         (1'b1),
      .bus_start_i      (ctrl_bus.start_det | ctrl_bus.rstart_det),
      .bus_stop_i       (ctrl_bus.stop_det),
      .in_hdr_mode_i    (in_hdr_mode),
      .t_bus_free_i     (20'd13),
      .t_bus_idle_i     (20'd66600),
      .t_bus_available_i(20'd333),
      .bus_busy_o       (bus_busy),
      .bus_free_o       (bus_free),
      .bus_idle_o       (bus_idle),
      .bus_available_o  (bus_available)
  );

  // ===========================================================================
  // 3. Bus TX / RX Flow & Target FSM / CCC Multiplexer
  // ===========================================================================
  bus_tx_req_t bus_tx_req, bus_tx_req_fsm, bus_tx_req_ccc;
  bus_tx_rsp_t bus_tx_rsp, bus_tx_rsp_fsm, bus_tx_rsp_ccc;
  bus_rx_req_t bus_rx_req, bus_rx_req_fsm, bus_rx_req_ccc;
  bus_rx_rsp_t bus_rx_rsp, bus_rx_rsp_fsm, bus_rx_rsp_ccc;

  ccc_cmd_e ccc_data;
  logic     ccc_valid;
  logic     ccc_done;
  logic     ccc_next;

  typedef enum logic {
    Fsm,
    Ccc
  } xfer_mux_sel_e;

  xfer_mux_sel_e xfer_mux_sel;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      xfer_mux_sel <= Fsm;
    end else if ((xfer_mux_sel == Fsm) && ccc_valid) begin
      xfer_mux_sel <= Ccc;
    end else if ((xfer_mux_sel == Ccc) && (ccc_done || ccc_next)) begin
      xfer_mux_sel <= Fsm;
    end
  end

  always_comb begin
    bus_tx_req     = '{drive_type: OpenDrain, req_type: RawBit, default: '0};
    bus_rx_req     = '{default: '0};
    bus_tx_rsp_fsm = '{default: '0};
    bus_tx_rsp_ccc = '{default: '0};
    bus_rx_rsp_fsm = '{default: '0};
    bus_rx_rsp_ccc = '{default: '0};

    unique case (xfer_mux_sel)
      Fsm: begin
        bus_tx_req     = bus_tx_req_fsm;
        bus_rx_req     = bus_rx_req_fsm;
        bus_tx_rsp_fsm = bus_tx_rsp;
        bus_rx_rsp_fsm = bus_rx_rsp;
      end
      Ccc: begin
        bus_tx_req     = bus_tx_req_ccc;
        bus_rx_req     = bus_rx_req_ccc;
        bus_tx_rsp_ccc = bus_tx_rsp;
        bus_rx_rsp_ccc = bus_rx_rsp;
      end
      default: ;
    endcase
  end

  bus_tx_flow u_bus_tx_flow (
      .clk_i,
      .rst_ni,
      .bus_i      (ctrl_bus),
      .tx_req_i   (bus_tx_req),
      .tx_rsp_o   (bus_tx_rsp),
      .sel_od_pp_o(sel_od_pp_o),
      .sda_oe_o   (sda_oe_o),
      .sda_o      (sda_o)
  );

  bus_rx_flow xbus_rx_flow (
      .clk_i,
      .rst_ni,
      .scl_posedge_i    (ctrl_bus.scl.pos_edge),
      .scl_stable_high_i(ctrl_bus.scl.stable_high),
      .sda_i            (ctrl_bus.sda.value),
      .rx_req_i         (bus_rx_req),
      .rx_rsp_o         (bus_rx_rsp)
  );

  // ===========================================================================
  // 4. Direct Byte-Stream <-> Register Bank Bridge (1-Cycle Registered Read)
  // ===========================================================================
  logic      tx_pr_start;
  logic      tx_pr_abort;
  logic      tx_fifo_rready;
  i3c_byte_t tx_fifo_rdata;
  logic      tx_host_nack;

  logic      rx_fifo_wvalid;
  i3c_byte_t rx_fifo_wdata;
  logic      rx_last_byte;
  logic      te2_err_priv_wr;

  logic [RegAddrWidth-1:0] reg_addr_q;
  logic                    addr_phase_q;

  // Combinational outputs to Register Bank:
  // - On Private Write data bytes (!addr_phase_q): drive reg_addr_q, rx_fifo_wdata, reg_we_o=1
  // - On Private Read start (tx_pr_start): drive reg_addr_q, reg_re_o=1
  // - On Private Read byte completion (tx_fifo_rready): prefetch reg_addr_q + 1, reg_re_o=1
  assign reg_we_o      = rx_fifo_wvalid && !te2_err_priv_wr && !addr_phase_q;
  assign reg_wdata_o   = rx_fifo_wdata[RegDataWidth-1:0];
  assign reg_re_o      = tx_pr_start || tx_fifo_rready;
  assign reg_addr_o    = tx_fifo_rready ? (reg_addr_q + 1'b1) : reg_addr_q;
  assign tx_fifo_rdata = i3c_byte_t'(reg_rdata_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_addr_q   <= '0;
      addr_phase_q <= 1'b1;
    end else begin
      // Reset address phase on every Start, Repeated Start, or Stop
      if (ctrl_bus.start_det || ctrl_bus.rstart_det || ctrl_bus.stop_det) begin
        addr_phase_q <= 1'b1;
      end else if (rx_fifo_wvalid && !te2_err_priv_wr) begin
        if (addr_phase_q) begin
          // First byte of Private Write sets the register pointer
          reg_addr_q   <= rx_fifo_wdata[RegAddrWidth-1:0];
          addr_phase_q <= 1'b0;
        end else begin
          // Subsequent bytes of Private Write auto-increment the pointer
          reg_addr_q <= reg_addr_q + 1'b1;
        end
      end else if (tx_fifo_rready) begin
        // Advance pointer to prefetch next byte in multi-byte Private Read
        reg_addr_q <= reg_addr_q + 1'b1;
      end else if (tx_pr_abort) begin
        // Controller ended read on T-bit; roll back the prefetched increment
        reg_addr_q <= reg_addr_q - 1'b1;
      end
    end
  end

  // ===========================================================================
  // 5. I3C Target FSM & CCC Engine
  // ===========================================================================
  logic      te0_enable, te0_err, te0_err_combined;
  logic      te1_err_ccc, te2_err_ccc, te3_err_ccc, te4_err_ccc, te5_err_ccc, framing_err_ccc;
  logic      protocol_err;
  logic [15:0] status_fmt1_q;

  assign protocol_err = te1_err_ccc | te2_err_ccc | te2_err_priv_wr | framing_err_ccc;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      status_fmt1_q <= 16'h0000;
    end else if (get_status_done) begin
      status_fmt1_q[5] <= 1'b0;
    end else if (protocol_err) begin
      status_fmt1_q[5] <= 1'b1;
    end
  end

  logic       event_target_nack, event_cmd_complete, event_unexp_stop;
  logic       event_tx_arbitration_lost, event_tx_bus_timeout, event_read_cmd_received;
  logic [7:0] bus_addr;
  logic       bus_addr_valid;
  logic       rx_overflow_err;
  logic       virtual_device_sel;
  logic       xfer_in_progress;
  ibi_status_e ibi_status;
  logic       ibi_status_we;

  i3c_target_fsm xi3c_target_fsm (
      .clk_i,
      .rst_ni,
      .target_enable_i            (1'b1),

      .scl_negedge_i              (ctrl_bus.scl.neg_edge),
      .bus_start_det_i            (ctrl_bus.start_det),
      .bus_rstart_det_i           (ctrl_bus.rstart_det),
      .bus_stop_det_i             (ctrl_bus.stop_det),

      .bus_available_i            (bus_available),
      .bus_timeout_i              (1'b0),
      .arbitration_lost_i,

      .target_idle_o              (),

      .bus_tx_req_o               (bus_tx_req_fsm),
      .bus_tx_rsp_i               (bus_tx_rsp_fsm),
      .bus_rx_req_o               (bus_rx_req_fsm),
      .bus_rx_rsp_i               (bus_rx_rsp_fsm),

      // Direct connection to Register Bank Bridge (Zero FIFOs)
      .tx_pr_start_o              (tx_pr_start),
      .tx_pr_abort_o              (tx_pr_abort),
      .tx_desc_avail_i            (1'b1),
      .tx_fifo_rvalid_i           (1'b1),
      .tx_fifo_rready_o           (tx_fifo_rready),
      .tx_fifo_rdata_i            (tx_fifo_rdata),
      .tx_host_nack_o             (tx_host_nack),
      .tx_last_byte_i             (1'b0),

      .rx_fifo_wvalid_o           (rx_fifo_wvalid),
      .rx_fifo_wdata_o            (rx_fifo_wdata),
      .rx_fifo_wready_i           (1'b1),
      .rx_last_byte_o             (rx_last_byte),

      .ibi_byte_valid_i           (1'b0),
      .ibi_byte_ready_o           (),
      .ibi_byte_i                 ('0),
      .ibi_byte_last_i            (1'b0),
      .ibi_byte_flush_o           (),

      .target_sta_addr_i          (StaticAddr),
      .target_sta_addr_valid_i    (StaticAddrValid),
      .target_dyn_addr_i          (target_dyn_addr_q),
      .target_dyn_addr_valid_i    (target_dyn_addr_valid_q),

      .virtual_target_sta_addr_i      (7'h00),
      .virtual_target_sta_addr_valid_i(1'b0),
      .virtual_target_dyn_addr_i      (7'h00),
      .virtual_target_dyn_addr_valid_i(1'b0),

      .target_ibi_addr_valid_i    (target_dyn_addr_valid_q),
      .target_ibi_addr_i          (target_dyn_addr_q),

      .event_target_nack_o        (event_target_nack),
      .event_cmd_complete_o       (event_cmd_complete),
      .event_unexp_stop_o         (event_unexp_stop),
      .event_tx_arbitration_lost_o(event_tx_arbitration_lost),
      .event_tx_bus_timeout_o     (event_tx_bus_timeout),
      .event_read_cmd_received_o  (event_read_cmd_received),

      .target_reset_detect_i      (target_reset_detect),
      .hdr_exit_detect_i          (hdr_exit_detect),
      .in_hdr_mode_i              (in_hdr_mode),

      .ibi_enable_i               (ibi_enable_q),
      .ibi_retry_num_i            (3'd0),
      .ibi_retry_ctr_rst_i        (1'b0),
      .ibi_status_o               (ibi_status),
      .ibi_status_we_o            (ibi_status_we),

      .ccc_data_o                 (ccc_data),
      .ccc_valid_o                (ccc_valid),
      .is_ccc_done_i              (ccc_done),
      .is_next_ccc_i              (ccc_next),

      .te0_enable_i               (te0_enable),
      .te0_err_o                  (te0_err),
      .is_hotjoin_done_i          (1'b0),
      .te2_err_det_en_i           (1'b1),

      .last_addr_o                (bus_addr),
      .last_addr_valid_o          (bus_addr_valid),
      .rx_overflow_err_o          (rx_overflow_err),
      .te2_err_priv_wr            (te2_err_priv_wr),
      .virtual_device_sel_o       (virtual_device_sel),
      .xfer_in_progress_o         (xfer_in_progress)
  );

  ccc xccc (
      .clk_i,
      .rst_ni,
      .arbitration_lost_i,

      .ccc_data_i                         (ccc_data),
      .ccc_valid_i                        (ccc_valid),
      .done_fsm_o                         (ccc_done),
      .next_ccc_o                         (ccc_next),

      .te0_enable_o                       (te0_enable),
      .te0_err_i                          (te0_err),
      .te0_err_o                          (te0_err_combined),
      .te1_err_o                          (te1_err_ccc),
      .te2_err_ccc_o                      (te2_err_ccc),
      .te3_err_o                          (te3_err_ccc),
      .te4_err_o                          (te4_err_ccc),
      .te5_err_o                          (te5_err_ccc),
      .framing_err_o                      (framing_err_ccc),

      .te0_err_det_en_i                   (1'b1),
      .te1_err_det_en_i                   (1'b1),
      .te2_err_det_en_i                   (1'b1),
      .te3_err_det_en_i                   (1'b1),
      .te4_err_det_en_i                   (1'b1),
      .te5_err_det_en_i                   (1'b1),
      .framing_err_det_en_i               (1'b1),

      .bus_start_det_i                    (ctrl_bus.start_det),
      .bus_rstart_det_i                   (ctrl_bus.rstart_det),
      .bus_stop_det_i                     (ctrl_bus.stop_det),

      .bus_tx_req_o                       (bus_tx_req_ccc),
      .bus_tx_rsp_i                       (bus_tx_rsp_ccc),
      .bus_rx_req_o                       (bus_rx_req_ccc),
      .bus_rx_rsp_i                       (bus_rx_rsp_ccc),

      .target_sta_address_i               (StaticAddr),
      .target_sta_address_valid_i         (StaticAddrValid),
      .target_dyn_address_i               (target_dyn_addr_q),
      .target_dyn_address_valid_i         (target_dyn_addr_valid_q),

      .virtual_target_sta_address_i       (7'h00),
      .virtual_target_sta_address_valid_i (1'b0),
      .virtual_target_dyn_address_i       (7'h00),
      .virtual_target_dyn_address_valid_i (1'b0),

      .enec_ibi_o                         (enec_ibi),
      .enec_crr_o                         (enec_crr),
      .enec_hj_o                          (enec_hj),
      .disec_ibi_o                        (disec_ibi),
      .disec_crr_o                        (disec_crr),
      .disec_hj_o                         (disec_hj),

      .entas0_o                           (),
      .entas1_o                           (),
      .entas2_o                           (),
      .entas3_o                           (),

      .rstdaa_o                           (rstdaa),
      .entdaa_o                           (),

      .get_mwl_i                          (mwl_q),
      .set_mwl_o                          (set_mwl),
      .mwl_o                              (mwl_from_ccc),
      .get_mrl_i                          (mrl_q),
      .set_mrl_o                          (set_mrl),
      .mrl_o                              (mrl_from_ccc),

      .get_ibil_i                         (ibil_q),
      .set_ibil_o                         (set_ibil),
      .ibil_o                             (ibil_from_ccc),

      .ent_tm_o                           (),
      .tm_o                               (),

      .exit_hdr_i                         (hdr_exit_detect),
      .in_hdr_mode_o                      (in_hdr_mode),
      .in_hdr_err_mode_o                  (in_hdr_err_mode),

      .set_dasa_o                         (set_dasa),
      .set_dasa_valid_o                   (set_dasa_valid),
      .set_dasa_virtual_device_o          (set_dasa_virtual_device),
      .set_aasa_o                         (set_aasa),
      .set_aasa_virt_o                    (set_aasa_virt),
      .set_newda_o                        (set_newda),
      .set_newda_virtual_device_o         (set_newda_virtual_device),
      .newda_o                            (newda),

      .rst_action_o                       (rst_action),
      .rst_action_valid_o                 (rst_action_valid),

      .get_pid_i                          (ProvisionedId),
      .get_bcr_i                          (Bcr),
      .get_dcr_i                          (Dcr),
      .virtual_get_pid_i                  (48'h0),
      .virtual_get_bcr_i                  (8'h0),
      .virtual_get_dcr_i                  (8'h0),

      .get_status_fmt1_i                  (status_fmt1_q),
      .get_acccr_i                        (1'b0),
      .set_brgtgt_o                       (),
      .get_mxds_i                         (1'b0),
      .get_status_done_o                  (get_status_done),

      .target_reset_detect_i              (target_reset_detect),
      .peripheral_reset_done_i,
      .peripheral_reset_o,
      .escalated_reset_o
  );

endmodule
