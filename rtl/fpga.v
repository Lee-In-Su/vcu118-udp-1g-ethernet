/*

Copyright (c) 2014-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA top-level module
 */
module fpga (
    /*
     * Clock: 125MHz LVDS
     * Reset: Push button, active low
     */
    input  wire       clk_125mhz_p,
    input  wire       clk_125mhz_n,
    input  wire       reset,

    /*
     * GPIO
     */
    input  wire       btnu,
    input  wire       btnl,
    input  wire       btnd,
    input  wire       btnr,
    input  wire       btnc,
    input  wire [3:0] sw,
    output wire [7:0] led,

    /*
     * Ethernet: 1000BASE-T SGMII
     */
    input  wire       phy_sgmii_rx_p,
    input  wire       phy_sgmii_rx_n,
    output wire       phy_sgmii_tx_p,
    output wire       phy_sgmii_tx_n,
    input  wire       phy_sgmii_clk_p,
    input  wire       phy_sgmii_clk_n,
    output wire       phy_reset_n,
    input  wire       phy_int_n,
    inout  wire       phy_mdio,
    output wire       phy_mdc,

    /*
     * UART: 500000 bps, 8N1
     */
    input  wire       uart_rxd,
    output wire       uart_txd,
    output wire       uart_rts,
    input  wire       uart_cts
);

// Clock and reset

wire clk_125mhz_ibufg;

// Internal 125 MHz clock
wire clk_125mhz_mmcm_out;
wire clk_125mhz_int;
wire rst_125mhz_int;
wire eth_rst_125mhz_int;
wire dl_rst_125mhz_int;

wire mmcm_rst = reset;
wire mmcm_locked;
wire mmcm_clkfb;

IBUFGDS #(
   .DIFF_TERM("FALSE"),
   .IBUF_LOW_PWR("FALSE")   
)
clk_125mhz_ibufg_inst (
   .O   (clk_125mhz_ibufg),
   .I   (clk_125mhz_p),
   .IB  (clk_125mhz_n) 
);

// MMCM instance
// 125 MHz in, 125 MHz out
// PFD range: 10 MHz to 500 MHz
// VCO range: 800 MHz to 1600 MHz
// M = 8, D = 1 sets Fvco = 1000 MHz (in range)
// Divide by 8 to get output frequency of 125 MHz
MMCME3_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKOUT0_DIVIDE_F(8),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0),
    .CLKOUT1_DIVIDE(1),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(0),
    .CLKOUT2_DIVIDE(1),
    .CLKOUT2_DUTY_CYCLE(0.5),
    .CLKOUT2_PHASE(0),
    .CLKOUT3_DIVIDE(1),
    .CLKOUT3_DUTY_CYCLE(0.5),
    .CLKOUT3_PHASE(0),
    .CLKOUT4_DIVIDE(1),
    .CLKOUT4_DUTY_CYCLE(0.5),
    .CLKOUT4_PHASE(0),
    .CLKOUT5_DIVIDE(1),
    .CLKOUT5_DUTY_CYCLE(0.5),
    .CLKOUT5_PHASE(0),
    .CLKOUT6_DIVIDE(1),
    .CLKOUT6_DUTY_CYCLE(0.5),
    .CLKOUT6_PHASE(0),
    .CLKFBOUT_MULT_F(8),
    .CLKFBOUT_PHASE(0),
    .DIVCLK_DIVIDE(1),
    .REF_JITTER1(0.010),
    .CLKIN1_PERIOD(8.0),
    .STARTUP_WAIT("FALSE"),
    .CLKOUT4_CASCADE("FALSE")
)
clk_mmcm_inst (
    .CLKIN1(clk_125mhz_ibufg),
    .CLKFBIN(mmcm_clkfb),
    .RST(mmcm_rst),
    .PWRDWN(1'b0),
    .CLKOUT0(clk_125mhz_mmcm_out),
    .CLKOUT0B(),
    .CLKOUT1(),
    .CLKOUT1B(),
    .CLKOUT2(),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6(),
    .CLKFBOUT(mmcm_clkfb),
    .CLKFBOUTB(),
    .LOCKED(mmcm_locked)
);

BUFG
clk_125mhz_bufg_inst (
    .I(clk_125mhz_mmcm_out),
    .O(clk_125mhz_int)
);

sync_reset #(
    .N(4)
)
sync_reset_125mhz_inst (
    .clk(clk_125mhz_int),
    .rst(~mmcm_locked),
    .out(rst_125mhz_int)
);

localparam ETH_RECOVERY_TOTAL_COUNT = 26'd62500000; // 500 ms at 125 MHz
localparam ETH_RECOVERY_RESET_COUNT = 26'd2500000;  // 20 ms at 125 MHz

wire eth_recovery_req;
reg [7:0] eth_recovery_count_reg = 8'd0;
reg [25:0] eth_recovery_timer_reg = 26'd0;
wire eth_recovery_rst = eth_recovery_timer_reg > (ETH_RECOVERY_TOTAL_COUNT-ETH_RECOVERY_RESET_COUNT);

// Keep recovery telemetry active, but do not reset PCS/MAC during SGMII bring-up.
assign eth_rst_125mhz_int = rst_125mhz_int;
assign dl_rst_125mhz_int = rst_125mhz_int;

always @(posedge clk_125mhz_int) begin
    if (rst_125mhz_int) begin
        eth_recovery_timer_reg <= 26'd0;
        eth_recovery_count_reg <= 8'd0;
    end else if (eth_recovery_timer_reg != 0) begin
        eth_recovery_timer_reg <= eth_recovery_timer_reg - 1'b1;
    end else if (eth_recovery_req) begin
        eth_recovery_timer_reg <= ETH_RECOVERY_TOTAL_COUNT;
        eth_recovery_count_reg <= eth_recovery_count_reg + 1'b1;
    end
end

// GPIO
wire btnu_int;
wire btnl_int;
wire btnd_int;
wire btnr_int;
wire btnc_int;
wire [3:0] sw_int;

debounce_switch #(
    .WIDTH(9),
    .N(4),
    .RATE(125000)
)
debounce_switch_inst (
    .clk(clk_125mhz_int),
    .rst(rst_125mhz_int),
    .in({btnu,
        btnl,
        btnd,
        btnr,
        btnc,
        sw}),
    .out({btnu_int,
        btnl_int,
        btnd_int,
        btnr_int,
        btnc_int,
        sw_int})
);

wire uart_rxd_int;
wire uart_cts_int;

sync_signal #(
    .WIDTH(2),
    .N(2)
)
sync_signal_inst (
    .clk(clk_125mhz_int),
    .in({uart_rxd, uart_cts}),
    .out({uart_rxd_int, uart_cts_int})
);

// SGMII interface to PHY
wire phy_gmii_clk_int;
wire phy_gmii_rst_int;
wire phy_gmii_clk_en_int;
wire phy_gmii_clk_en_mac = ~phy_gmii_clk_en_int;
wire [7:0] phy_gmii_txd_int;
wire phy_gmii_tx_en_int;
wire phy_gmii_tx_er_int;
wire [7:0] phy_gmii_rxd_int;
wire phy_gmii_rx_dv_int;
wire phy_gmii_rx_er_int;

wire [15:0] pcspma_status_vector;
wire [15:0] pcspma_riu_rddata_const = 16'd0;
wire pcspma_tx_logic_reset;
wire pcspma_rx_logic_reset;
wire pcspma_tx_locked;
wire pcspma_rx_locked;
wire pcspma_an_interrupt;
reg pcspma_an_interrupt_seen_reg = 1'b0;

always @(posedge clk_125mhz_int) begin
    if (eth_rst_125mhz_int) begin
        pcspma_an_interrupt_seen_reg <= 1'b0;
    end else if (pcspma_an_interrupt) begin
        pcspma_an_interrupt_seen_reg <= 1'b1;
    end
end

// UART diagnostic packing for PCS/PMA bring-up:
// [15]=tx_locked [14]=rx_locked [13]=tx_logic_reset [12]=rx_logic_reset
// [11]=phy_gmii_rst [10]=raw_sgmii_clk_en [9]=mac_clk_en [8]=an_interrupt_seen
// [7:0]=PCS/PMA status low bits
wire [15:0] pcspma_uart_status_vector = {
    pcspma_tx_locked,
    pcspma_rx_locked,
    pcspma_tx_logic_reset,
    pcspma_rx_logic_reset,
    phy_gmii_rst_int,
    phy_gmii_clk_en_int,
    phy_gmii_clk_en_mac,
    pcspma_an_interrupt_seen_reg,
    pcspma_status_vector[7:0]
};

wire pcspma_status_link_status              = pcspma_status_vector[0];
wire pcspma_status_link_synchronization     = pcspma_status_vector[1];
wire pcspma_status_rudi_c                   = pcspma_status_vector[2];
wire pcspma_status_rudi_i                   = pcspma_status_vector[3];
wire pcspma_status_rudi_invalid             = pcspma_status_vector[4];
wire pcspma_status_rxdisperr                = pcspma_status_vector[5];
wire pcspma_status_rxnotintable             = pcspma_status_vector[6];
wire pcspma_status_phy_link_status          = pcspma_status_vector[7];
wire [1:0] pcspma_status_remote_fault_encdg = pcspma_status_vector[9:8];
wire [1:0] pcspma_status_speed              = pcspma_status_vector[11:10];
wire pcspma_status_duplex                   = pcspma_status_vector[12];
wire pcspma_status_remote_fault             = pcspma_status_vector[13];
wire [1:0] pcspma_status_pause              = pcspma_status_vector[15:14];

wire [4:0] pcspma_config_vector = 5'b00001;

reg [29:0] pcspma_config_seq_reg = 30'd0;
wire pcspma_configuration_valid = pcspma_config_seq_reg == 30'd125000000;
wire pcspma_an_adv_config_val = pcspma_config_seq_reg == 30'd125000008;
wire pcspma_an_restart_config = pcspma_config_seq_reg == 30'd937500016;

reg pcspma_configuration_valid_seen_reg = 1'b0;
reg pcspma_an_adv_config_val_seen_reg = 1'b0;
reg pcspma_an_restart_config_seen_reg = 1'b0;

always @(posedge clk_125mhz_int) begin
    if (eth_rst_125mhz_int) begin
        pcspma_configuration_valid_seen_reg <= 1'b0;
        pcspma_an_adv_config_val_seen_reg <= 1'b0;
        pcspma_an_restart_config_seen_reg <= 1'b0;
    end else begin
        if (pcspma_configuration_valid) begin
            pcspma_configuration_valid_seen_reg <= 1'b1;
        end
        if (pcspma_an_adv_config_val) begin
            pcspma_an_adv_config_val_seen_reg <= 1'b1;
        end
        if (pcspma_an_restart_config) begin
            pcspma_an_restart_config_seen_reg <= 1'b1;
        end
    end
end

wire [15:0] pcspma_diag_vector = {
    pcspma_configuration_valid_seen_reg,
    pcspma_an_adv_config_val_seen_reg,
    pcspma_an_restart_config_seen_reg,
    pcspma_an_interrupt_seen_reg,
    phy_gmii_clk_en_int,
    phy_gmii_clk_en_mac,
    pcspma_tx_locked,
    pcspma_rx_locked,
    pcspma_tx_logic_reset,
    pcspma_rx_logic_reset,
    pcspma_config_seq_reg[29:24]
};

always @(posedge clk_125mhz_int) begin
    if (eth_rst_125mhz_int) begin
        pcspma_config_seq_reg <= 30'd0;
    end else if (!pcspma_tx_locked && (pcspma_an_restart_config || (pcspma_config_seq_reg == 30'h3fffffff))) begin
        pcspma_config_seq_reg <= 30'd0;
    end else if (pcspma_config_seq_reg != 30'h3fffffff) begin
        pcspma_config_seq_reg <= pcspma_config_seq_reg + 1'b1;
    end
end

wire [15:0] pcspma_an_config_vector = 16'hD801;
bd_525a_pcs_pma_0 
eth_pcspma (
    // SGMII
    .txp_0                  (phy_sgmii_tx_p),
    .txn_0                  (phy_sgmii_tx_n),
    .rxp_0                  (phy_sgmii_rx_p),
    .rxn_0                  (phy_sgmii_rx_n),

    // Ref clock from PHY
    .refclk625_p            (phy_sgmii_clk_p),
    .refclk625_n            (phy_sgmii_clk_n),

    // async reset
    .reset                  (eth_rst_125mhz_int),

    // clock and reset outputs
    .clk125_out             (phy_gmii_clk_int),
    .clk312_out             (),
    .rst_125_out            (phy_gmii_rst_int),
    .tx_logic_reset         (pcspma_tx_logic_reset),
    .rx_logic_reset         (pcspma_rx_logic_reset),
    .tx_locked              (pcspma_tx_locked),
    .rx_locked              (pcspma_rx_locked),
    .tx_pll_clk_out         (),
    .rx_pll_clk_out         (),

    // MAC clocking
    .sgmii_clk_r_0          (),
    .sgmii_clk_f_0          (),
    .sgmii_clk_en_0         (phy_gmii_clk_en_int),
    
    // Speed control
    .speed_is_10_100_0      (1'b0),
    .speed_is_100_0         (1'b0),

    // Internal GMII
    .gmii_txd_0             (phy_gmii_txd_int),
    .gmii_tx_en_0           (phy_gmii_tx_en_int),
    .gmii_tx_er_0           (phy_gmii_tx_er_int),
    .gmii_rxd_0             (phy_gmii_rxd_int),
    .gmii_rx_dv_0           (phy_gmii_rx_dv_int),
    .gmii_rx_er_0           (phy_gmii_rx_er_int),
    .gmii_isolate_0         (),

    // Configuration
    .configuration_vector_0 (pcspma_config_vector),
    .configuration_valid_0  (pcspma_configuration_valid),
    .phyaddr_0              (5'd3),

    .an_interrupt_0         (pcspma_an_interrupt),
    .an_adv_config_vector_0 (pcspma_an_config_vector),
    .an_adv_config_val_0    (pcspma_an_adv_config_val),
    .an_restart_config_0    (pcspma_an_restart_config),

    // Status
    .status_vector_0        (pcspma_status_vector),
    .signal_detect_0        (1'b1),

    // PCS/PMA management MDIO is unused in this lightweight path; the external PHY MDIO remains driven by mdio_master below.
    .ext_mdc_0              (),
    .ext_mdio_i_0           (1'b1),
    .ext_mdio_o_0           (),
    .ext_mdio_t_0           (),
    .mdio_t_in_0            (1'b1),
    .mdc_0                  (1'b0),
    .mdio_i_0               (1'b1),
    .mdio_o_0               (),
    .mdio_t_0               (),

    // Cascade
    .tx_bsc_rst_out         (),
    .rx_bsc_rst_out         (),
    .tx_bs_rst_out          (),
    .rx_bs_rst_out          (),
    .tx_rst_dly_out         (),
    .rx_rst_dly_out         (),
    .tx_bsc_en_vtc_out      (),
    .rx_bsc_en_vtc_out      (),
    .tx_bs_en_vtc_out       (),
    .rx_bs_en_vtc_out       (),
    .riu_clk_out            (),
    .riu_addr_out           (),
    .riu_wr_data_out        (),
    .riu_wr_en_out          (),
    .riu_nibble_sel_out     (),
    .riu_rddata_1           (16'b0),
    .riu_valid_1            (1'b0),
    .riu_prsnt_1            (1'b0),
    .riu_rddata_2           (16'b0),
    .riu_valid_2            (1'b0),
    .riu_prsnt_2            (1'b0),
    .riu_rddata_3           (16'b0),
    .riu_valid_3            (1'b0),
    .riu_prsnt_3            (1'b0),
    .rx_btval_1             (),
    .rx_btval_2             (),
    .rx_btval_3             (),
    .tx_dly_rdy_1           (1'b1),
    .rx_dly_rdy_1           (1'b1),
    .rx_vtc_rdy_1           (1'b1),
    .tx_vtc_rdy_1           (1'b1),
    .tx_dly_rdy_2           (1'b1),
    .rx_dly_rdy_2           (1'b1),
    .rx_vtc_rdy_2           (1'b1),
    .tx_vtc_rdy_2           (1'b1),
    .tx_dly_rdy_3           (1'b1),
    .rx_dly_rdy_3           (1'b1),
    .rx_vtc_rdy_3           (1'b1),
    .tx_vtc_rdy_3           (1'b1),
    .tx_rdclk_out           ()
);

reg [19:0] delay_reg = 20'hfffff;

reg [4:0] mdio_cmd_phy_addr = 5'h03;
reg [4:0] mdio_cmd_reg_addr = 5'h00;
reg [15:0] mdio_cmd_data = 16'd0;
reg [1:0] mdio_cmd_opcode = 2'b01;
reg mdio_cmd_valid = 1'b0;
wire mdio_cmd_ready;
wire [15:0] mdio_data_out;
wire mdio_data_out_valid;

reg [15:0] mdio_bmcr_reg = 16'd0;
reg [15:0] mdio_bmsr_reg = 16'd0;
reg [15:0] mdio_phycr_reg = 16'd0;
reg [15:0] mdio_physts_reg = 16'd0;
reg [15:0] mdio_cfg2_reg = 16'd0;
reg [15:0] mdio_recr_reg = 16'd0;
reg [15:0] mdio_anar_reg = 16'd0;
reg [15:0] mdio_anlpar_reg = 16'd0;
reg [15:0] mdio_gbcr_reg = 16'd0;
reg [15:0] mdio_gbsr_reg = 16'd0;
reg [15:0] mdio_ext_cfg4_reg = 16'd0;
reg [15:0] mdio_ext_sgmii_sts_reg = 16'd0;
reg [15:0] mdio_ext_sgmii_ctl1_reg = 16'd0;
reg [15:0] mdio_ext_strap_sts1_reg = 16'd0;
reg [15:0] mdio_reg_1f_reg = 16'd0;
reg [15:0] mdio_ext_16f_reg = 16'd0;
reg [5:0] state_reg = 0;
reg [3:0] toggle_cooldown_reg = 4'd0;
reg [3:0] mdio_read_slot_reg = 4'd0;
reg mdio_read_pending_reg = 1'b0;

always @(posedge clk_125mhz_int) begin
    if (eth_rst_125mhz_int) begin
        state_reg <= 6'd48;
        delay_reg <= 20'hfffff;
        mdio_cmd_reg_addr <= 5'h00;
        mdio_cmd_data <= 16'd0;
        mdio_cmd_opcode <= 2'b01;
        mdio_cmd_valid <= 1'b0;
        mdio_read_slot_reg <= 4'd0;
        mdio_read_pending_reg <= 1'b0;
        mdio_bmcr_reg <= 16'd0;
        mdio_bmsr_reg <= 16'd0;
        mdio_phycr_reg <= 16'd0;
        mdio_physts_reg <= 16'd0;
        mdio_cfg2_reg <= 16'd0;
        mdio_recr_reg <= 16'd0;
        mdio_anar_reg <= 16'd0;
        mdio_anlpar_reg <= 16'd0;
        mdio_gbcr_reg <= 16'd0;
        mdio_gbsr_reg <= 16'd0;
        mdio_ext_cfg4_reg <= 16'd0;
        mdio_ext_sgmii_sts_reg <= 16'd0;
        mdio_ext_sgmii_ctl1_reg <= 16'd0;
        mdio_ext_strap_sts1_reg <= 16'd0;
        mdio_reg_1f_reg <= 16'd0;
        mdio_ext_16f_reg <= 16'd0;
    end else begin
        mdio_cmd_valid <= mdio_cmd_valid & !mdio_cmd_ready;
        if (mdio_read_pending_reg) begin
            if (mdio_data_out_valid) begin
                mdio_read_pending_reg <= 1'b0;
                case (mdio_read_slot_reg)
                    4'd0: begin
                        mdio_bmcr_reg <= mdio_data_out;
                        state_reg <= 6'd14;
                    end
                    4'd1: begin
                        mdio_bmsr_reg <= mdio_data_out;
                        state_reg <= 6'd15;
                    end
                    4'd2: begin
                        mdio_phycr_reg <= mdio_data_out;
                        state_reg <= 6'd16;
                    end
                    4'd3: begin
                        mdio_physts_reg <= mdio_data_out;
                        state_reg <= 6'd17;
                    end
                    4'd4: begin
                        mdio_cfg2_reg <= mdio_data_out;
                        state_reg <= 6'd18;
                    end
                    4'd5: begin
                        mdio_recr_reg <= mdio_data_out;
                        state_reg <= 6'd19;
                    end
                    4'd6: begin
                        mdio_anar_reg <= mdio_data_out;
                        state_reg <= 6'd20;
                    end
                    4'd7: begin
                        mdio_anlpar_reg <= mdio_data_out;
                        state_reg <= 6'd21;
                    end
                    4'd8: begin
                        mdio_gbcr_reg <= mdio_data_out;
                        state_reg <= 6'd22;
                    end
                    4'd9: begin
                        mdio_gbsr_reg <= mdio_data_out;
                        state_reg <= 6'd23;
                    end
                    4'd10: begin
                        mdio_ext_cfg4_reg <= mdio_data_out;
                        state_reg <= 6'd27;
                    end
                    4'd11: begin
                        mdio_ext_sgmii_sts_reg <= mdio_data_out;
                        state_reg <= 6'd31;
                    end
                    4'd12: begin
                        mdio_ext_sgmii_ctl1_reg <= mdio_data_out;
                        state_reg <= 6'd35;
                    end
                    4'd13: begin
                        mdio_ext_strap_sts1_reg <= mdio_data_out;
                        state_reg <= 6'd39;
                    end
                    4'd14: begin
                        mdio_reg_1f_reg <= mdio_data_out;
                        state_reg <= 6'd40;
                    end
                    4'd15: begin
                        mdio_ext_16f_reg <= mdio_data_out;
                        delay_reg <= 20'hfffff;
                        state_reg <= 6'd49;
                    end
                    default: begin
                        state_reg <= 6'd13;
                    end
                endcase
            end
        end else if (delay_reg > 0) begin
            delay_reg <= delay_reg - 1;
        end else if (!mdio_cmd_ready) begin
            // wait for ready
            state_reg <= state_reg;
        end else begin
            mdio_cmd_valid <= 1'b0;
            case (state_reg)
                // Apply the DP83867 profile observed from the working 1G reference design.
                // write 0x1030 to CFG4 (0x0031), clearing INT_TST_MODE_1 while leaving the other observed bits intact.
                6'd0: begin
                    // write to REGCR to load address
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd1;
                end
                6'd1: begin
                    // write address of CFG4 to ADDAR
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h0031;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd2;
                end
                6'd2: begin
                    // write to REGCR to load data
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd3;
                end
                6'd3: begin
                    // write data for CFG4 to ADDAR
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h10B0;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd4;
                end
                // Test DP83867 SGMIICTL1 (0x00D3) bit 14 for VCU118 LVDS SGMII link.
                // write 0x4000 to SGMIICTL1 (0x00D3)
                6'd4: begin
                    // write to REGCR to load address
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd5;
                end
                6'd5: begin
                    // write address of SGMIICTL1 to ADDAR
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h00D3;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd6;
                end
                6'd6: begin
                    // write to REGCR to load data
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd7;
                end
                6'd7: begin
                    // write data for SGMIICTL1 to ADDAR
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h4000;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd44;
                end
                6'd8: begin
                    // PHYCTRL (0x10): reference 1G profile
                    mdio_cmd_reg_addr <= 5'h10;
                    mdio_cmd_data <= 16'h5848;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd9;
                end
                6'd9: begin
                    // CFG2 (0x14): reference 1G profile
                    mdio_cmd_reg_addr <= 5'h14;
                    mdio_cmd_data <= 16'h29C7;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd10;
                end
                6'd10: begin
                    // ANAR (0x04): reference 1G profile
                    mdio_cmd_reg_addr <= 5'h04;
                    mdio_cmd_data <= 16'h01E1;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd11;
                end
                6'd11: begin
                    // 1000BASE-T control (0x09): advertise 1000 full/half duplex
                    mdio_cmd_reg_addr <= 5'h09;
                    mdio_cmd_data <= 16'h1B00;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd12;
                end
                6'd12: begin
                    // BMCR (0x00): enable autonegotiation and restart link negotiation
                    mdio_cmd_reg_addr <= 5'h00;
                    mdio_cmd_data <= 16'h1140;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd13;
                end
                6'd13: begin
                    // read BMCR (0x00)
                    mdio_cmd_reg_addr <= 5'h00;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd0;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd14: begin
                    // read BMSR (0x01)
                    mdio_cmd_reg_addr <= 5'h01;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd1;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd15: begin
                    // read PHYCR (0x10)
                    mdio_cmd_reg_addr <= 5'h10;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd2;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd16: begin
                    // read PHYSTS (0x11)
                    mdio_cmd_reg_addr <= 5'h11;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd3;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd17: begin
                    // read CFG2 (0x14)
                    mdio_cmd_reg_addr <= 5'h14;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd4;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd18: begin
                    // read RECR / RX_ER counter (0x15)
                    mdio_cmd_reg_addr <= 5'h15;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd5;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd19: begin
                    // read ANAR / auto-negotiation advertisement (0x04)
                    mdio_cmd_reg_addr <= 5'h04;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd6;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd20: begin
                    // read ANLPAR / link partner ability (0x05)
                    mdio_cmd_reg_addr <= 5'h05;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd7;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd21: begin
                    // read 1000BASE-T control (0x09)
                    mdio_cmd_reg_addr <= 5'h09;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd8;
                    mdio_read_pending_reg <= 1'b1;
                end
                6'd22: begin
                    // read 1000BASE-T status (0x0A)
                    mdio_cmd_reg_addr <= 5'h0A;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd9;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Extended register readback: CFG4 (0x0031)
                6'd23: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd24;
                end
                6'd24: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h0031;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd25;
                end
                6'd25: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd26;
                end
                6'd26: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd10;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Extended register readback: SGMII_ANEG_STS (0x0037)
                6'd27: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd28;
                end
                6'd28: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h0037;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd29;
                end
                6'd29: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd30;
                end
                6'd30: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd11;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Extended register readback: SGMIICTL1 (0x00D3)
                6'd31: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd32;
                end
                6'd32: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h00D3;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd33;
                end
                6'd33: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd34;
                end
                6'd34: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd12;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Extended register readback: STRAP_STS1 (0x006E)
                6'd35: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd36;
                end
                6'd36: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h006E;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd37;
                end
                6'd37: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd38;
                end
                6'd38: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd13;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Standard register readback: PHYCR2 / PHY status control (0x1F)
                6'd39: begin
                    mdio_cmd_reg_addr <= 5'h1F;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd14;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Extended register readback: 10M SGMII rate adaptation control/status (0x016F)
                6'd40: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd41;
                end
                6'd41: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h016F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd42;
                end
                6'd42: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd43;
                end
                6'd43: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'd0;
                    mdio_cmd_opcode <= 2'b10;
                    mdio_cmd_valid <= 1'b1;
                    mdio_read_slot_reg <= 4'd15;
                    mdio_read_pending_reg <= 1'b1;
                end
                // Clear DP83867 10M SGMII rate adaptation bit observed in 0x016F readback.
                // Current XR=0x0095; write 0x0015 keeps other observed low bits and clears bit 7.
                6'd44: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd45;
                end
                6'd45: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h016F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd46;
                end
                6'd46: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd47;
                end
                6'd47: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h0015;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd8;
                end
                // DP83867 software reset before applying the SGMII/1G profile.
                // This tests whether SGMIICTL1/CFG4/0x016F require a fresh PHY reset
                // before the SGMII autoneg state machine can complete.
                6'd48: begin
                    mdio_cmd_reg_addr <= 5'h1F;
                    mdio_cmd_data <= 16'h4000;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    delay_reg <= 20'hfffff;
                    state_reg <= 6'd0;
                end
                // Gate: if SGMII not locked, restart DP83867 SGMII block before next read loop
                6'd49: begin
                    if (!pcspma_tx_locked && toggle_cooldown_reg == 4'd0) begin
                        state_reg <= 6'd50;
                    end else begin
                        if (toggle_cooldown_reg != 4'd0) begin
                            toggle_cooldown_reg <= toggle_cooldown_reg - 4'd1;
                        end
                        state_reg <= 6'd13;
                    end
                end
                // Write SGMIICTL1 = 0x0000 (disable SGMII to reset DP83867 SGMII TX)
                6'd50: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd51;
                end
                6'd51: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h00D3;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd52;
                end
                6'd52: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd53;
                end
                6'd53: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h0000;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd54;
                end
                // Write SGMIICTL1 = 0x4000 (re-enable SGMII)
                6'd54: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h001F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd55;
                end
                6'd55: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h00D3;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd56;
                end
                6'd56: begin
                    mdio_cmd_reg_addr <= 5'h0D;
                    mdio_cmd_data <= 16'h401F;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    state_reg <= 6'd57;
                end
                6'd57: begin
                    mdio_cmd_reg_addr <= 5'h0E;
                    mdio_cmd_data <= 16'h4000;
                    mdio_cmd_opcode <= 2'b01;
                    mdio_cmd_valid <= 1'b1;
                    toggle_cooldown_reg <= 4'd9;
                    state_reg <= 6'd13;
                end
            endcase
        end
    end
end

wire mdc;
wire mdio_i;
wire mdio_o;
wire mdio_t;

mdio_master
mdio_master_inst (
    .clk(clk_125mhz_int),
    .rst(eth_rst_125mhz_int),
    .cmd_phy_addr(mdio_cmd_phy_addr),
    .cmd_reg_addr(mdio_cmd_reg_addr),
    .cmd_data(mdio_cmd_data),
    .cmd_opcode(mdio_cmd_opcode),
    .cmd_valid(mdio_cmd_valid),
    .cmd_ready(mdio_cmd_ready),

    .data_out(mdio_data_out),
    .data_out_valid(mdio_data_out_valid),
    .data_out_ready(1'b1),

    .mdc_o(mdc),
    .mdio_i(mdio_i),
    .mdio_o(mdio_o),
    .mdio_t(mdio_t),

    .busy(),

    .prescale(8'd3)
);

assign phy_mdc = mdc;
assign mdio_i = phy_mdio;
assign phy_mdio = mdio_t ? 1'bz : mdio_o;

wire [7:0] led_int;
wire sample_axis_tvalid;
wire [159:0] sample_axis_tdata;
wire [31:0] sample_axis_tid;
wire sample_axis_tready;
wire dl_result_fifo_rd_en;

// Communication-only baseline: accept emitted DATA samples immediately and
// tie off the deep-learning result path. This keeps Ethernet/protocol testing
// isolated from the MLP datapath.
assign sample_axis_tready = 1'b1;

wire [15:0] dl_sample_fifo_level_reg = 16'd0;
wire [15:0] dl_model_result_count_reg = 16'd0;
wire [15:0] dl_model_logit0_reg = 16'd0;
wire [15:0] dl_model_logit1_reg = 16'd0;
wire [15:0] dl_model_logit2_reg = 16'd0;
wire [15:0] dl_result_fifo_level_reg = 16'd0;
wire [15:0] dl_result_fifo_overflow_count_reg = 16'd0;
wire [79:0] dl_result_fifo_tdata = 80'd0;
// SGMII interface debug:
// SW12:4 (sw[0]) off for payload byte, on for status vector
// SW12:3 (sw[1]) off for LSB of status vector, on for MSB
assign led = sw[0] ? (sw[1] ? pcspma_status_vector[15:8] : pcspma_status_vector[7:0]) : led_int;

fpga_core
core_inst (
    /*
     * Clock: 125MHz
     * Synchronous reset
     */
    .clk(clk_125mhz_int),
    .rst(eth_rst_125mhz_int),
    .state_rst(rst_125mhz_int),
    /*
     * GPIO
     */
    .btnu(btnu_int),
    .btnl(btnl_int),
    .btnd(btnd_int),
    .btnr(btnr_int),
    .btnc(btnc_int),
    .sw(sw_int),
    .led(led_int),
    /*
     * Ethernet: 1000BASE-T SGMII
     */
    .phy_gmii_clk(phy_gmii_clk_int),
    .phy_gmii_rst(phy_gmii_rst_int),
    .phy_gmii_clk_en(phy_gmii_clk_en_mac),
    .phy_gmii_rxd(phy_gmii_rxd_int),
    .phy_gmii_rx_dv(phy_gmii_rx_dv_int),
    .phy_gmii_rx_er(phy_gmii_rx_er_int),
    .phy_gmii_txd(phy_gmii_txd_int),
    .phy_gmii_tx_en(phy_gmii_tx_en_int),
    .phy_gmii_tx_er(phy_gmii_tx_er_int),
    .phy_reset_n(phy_reset_n),
    .phy_int_n(phy_int_n),
    .eth_recovery_req(eth_recovery_req),
    .eth_recovery_count(eth_recovery_count_reg),
    .pcspma_status_vector(pcspma_uart_status_vector),
    .pcspma_raw_status_vector(pcspma_status_vector),
    .pcspma_diag_vector(pcspma_diag_vector),
    .mdio_bmcr(mdio_bmcr_reg),
    .mdio_bmsr(mdio_bmsr_reg),
    .mdio_phycr(mdio_phycr_reg),
    .mdio_physts(mdio_physts_reg),
    .mdio_cfg2(mdio_cfg2_reg),
    .mdio_recr(mdio_recr_reg),
    .mdio_anar(mdio_anar_reg),
    .mdio_anlpar(mdio_anlpar_reg),
    .mdio_gbcr(mdio_gbcr_reg),
    .mdio_gbsr(mdio_gbsr_reg),
    .mdio_ext_cfg4(mdio_ext_cfg4_reg),
    .mdio_ext_sgmii_sts(mdio_ext_sgmii_sts_reg),
    .mdio_ext_sgmii_ctl1(mdio_ext_sgmii_ctl1_reg),
    .mdio_ext_strap_sts1(mdio_ext_strap_sts1_reg),
    .mdio_reg_1f(mdio_reg_1f_reg),
    .mdio_ext_16f(mdio_ext_16f_reg),

    .sample_axis_tvalid(sample_axis_tvalid),
    .sample_axis_tdata(sample_axis_tdata),
    .sample_axis_tid(sample_axis_tid),
    .sample_axis_tready(sample_axis_tready),
    .dl_sample_fifo_level(dl_sample_fifo_level_reg),
    .dl_result_count(dl_model_result_count_reg),
    .dl_logit0(dl_model_logit0_reg),
    .dl_logit1(dl_model_logit1_reg),
    .dl_logit2(dl_model_logit2_reg),
    .dl_result_fifo_level(dl_result_fifo_level_reg),
    .dl_result_fifo_overflow_count(dl_result_fifo_overflow_count_reg),
    .dl_result_fifo_tdata(dl_result_fifo_tdata),
    .dl_result_fifo_rd_en(dl_result_fifo_rd_en),
    /*
     * UART: 115200 bps, 8N1
     */
    .uart_rxd(uart_rxd_int),
    .uart_txd(uart_txd),
    .uart_rts(uart_rts),
    .uart_cts(uart_cts_int)
);

endmodule

`resetall





