//============================================================================
// Z8530 SCC Testbench - dual-clock, new bus protocol
//
// Bus protocol modelled here:
//   - rd_n / wr_n / a_b / d_c / data_in are driven valid 2 clk cycles BEFORE
//     cs_n is asserted, and remain valid 2 clk cycles AFTER cs_n is deasserted.
//   - cs_n is held low for 5 clk cycles per transaction.
//
// Clock domains:
//   - clk  : 50 MHz CPU/bus clock.
//   - sclk : ~3.6864 MHz BRG/serializer clock (real Lisa / Macintosh value).
//
// Baud rate used by the loopback/stress tests: TC = 1, x16  =>  38400 baud
// at sclk = 3.6864 MHz, which yields ~260 us per byte.
//============================================================================

`timescale 1ns / 1ps

module z8530_scc_tb;

// ---- Timing parameters ----
parameter CLK_PERIOD     = 50;      // 20 MHz system clock (matches Lisa MiSTer build)
parameter SCLK_PERIOD    = 271;     // 3.690 MHz (~3.6864 MHz)
parameter PCLK_PERIOD    = 250;     // 4 MHz peripheral clock (Channel A BRG source, BRG_SRC_A=0)
parameter BIT_TIME_NS    = 26042;   // 1/38400 s in ns (Channel B @ 3.6864 MHz, TC=1, x16)
parameter BIT_TIME_A_NS  = 24000;   // 1/41667 s in ns (Channel A @ 4 MHz, TC=1, x16)
parameter FRAME_WAIT_CLK = 12000;   // > one byte time (10 bits @ 38400 = 260 us = 5208 cycles @ 20 MHz)

// ---- Testbench signals ----
reg         clk;
reg         pclk;
reg         sclk;
reg         reset_n;
reg         cs_n;
reg         rd_n;
reg         wr_n;
reg         a_b;
reg         d_c;
reg  [7:0]  data_in;
wire [7:0]  data_out;
wire        data_oe;
wire        int_n;
reg         intack_n;

// Channel A serial
reg         rxca, txca, rxda, ctsa_n, dcda_n, synca_n;
wire        txda, rtsa_n, dtra_n;

// Channel B serial
reg         rxcb, txcb, rxdb, ctsb_n, dcdb_n, syncb_n;
wire        txdb, rtsb_n, dtrb_n;

// ---- DUT ----
z8530_scc dut (
    .clk        (clk),
    .pclk       (pclk),   // 4 MHz; Channel A BRG source (BRG_SRC_A=0)
    .sclk       (sclk),
    .reset_n    (reset_n),
    .cs_n       (cs_n),
    .rd_n       (rd_n),
    .wr_n       (wr_n),
    .a_b        (a_b),
    .d_c        (d_c),
    .data_in    (data_in),
    .data_out   (data_out),
    .data_oe    (data_oe),
    .int_n      (int_n),
    .intack_n   (intack_n),
    .rxca       (rxca),  .txca (txca), .rxda (rxda),
    .txda       (txda),  .ctsa_n (ctsa_n), .dcda_n (dcda_n), .synca_n (synca_n),
    .rtsa_n     (rtsa_n), .dtra_n (dtra_n),
    .rxcb       (rxcb),  .txcb (txcb), .rxdb (rxdb),
    .txdb       (txdb),  .ctsb_n (ctsb_n), .dcdb_n (dcdb_n), .syncb_n (syncb_n),
    .rtsb_n     (rtsb_n), .dtrb_n (dtrb_n)
);

// ---- Clock generators ----
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

initial begin
    pclk = 0;
    forever #(PCLK_PERIOD/2) pclk = ~pclk;
end

initial begin
    sclk = 0;
    forever #(SCLK_PERIOD/2) sclk = ~sclk;
end

//============================================================================
// Bus access primitives - implement the 2-5-2 protocol
//============================================================================

// Write transaction
//   Pre-condition: bus idle (cs_n=1, rd_n=1, wr_n=1).
//   1) Drive a_b/d_c/data_in/wr_n on a clk edge
//   2) Hold 2 clk cycles with cs_n high
//   3) Assert cs_n low; hold for 5 clk cycles
//   4) Deassert cs_n; hold bus 2 more clk cycles
//   5) Release wr_n and other signals
task bus_write;
    input        channel_a;  // 1=A, 0=B
    input        is_data;    // 1=Data reg, 0=Control reg
    input [7:0]  data;
    begin
        @(posedge clk);
        a_b     <= channel_a;
        d_c     <= is_data;
        data_in <= data;
        wr_n    <= 1'b0;
        rd_n    <= 1'b1;
        cs_n    <= 1'b1;
        repeat(2) @(posedge clk);   // setup: bus valid, cs_n high
        cs_n    <= 1'b0;
        repeat(5) @(posedge clk);   // cs_n asserted for 5 cycles
        cs_n    <= 1'b1;
        repeat(2) @(posedge clk);   // hold: bus valid, cs_n high
        wr_n    <= 1'b1;
        rd_n    <= 1'b1;
        a_b     <= 1'b0;
        d_c     <= 1'b0;
        data_in <= 8'h00;
        @(posedge clk);
    end
endtask

// Read transaction
//   Same timing as write, but rd_n asserted instead of wr_n.
//   data_out is sampled on the 4th clk cycle of cs_n low (combinational).
task bus_read;
    input        channel_a;
    input        is_data;
    output [7:0] data;
    begin
        @(posedge clk);
        a_b     <= channel_a;
        d_c     <= is_data;
        wr_n    <= 1'b1;
        rd_n    <= 1'b0;
        cs_n    <= 1'b1;
        data_in <= 8'h00;
        repeat(2) @(posedge clk);
        cs_n    <= 1'b0;
        repeat(4) @(posedge clk);    // 4 cycles into cs_n window
        data    = data_out;          // sample combinational output
        @(posedge clk);              // 5th cycle of cs_n low
        cs_n    <= 1'b1;
        repeat(2) @(posedge clk);    // hold: bus valid, cs_n high (allows RTL falling-edge FIFO pop / reg_ptr reset)
        rd_n    <= 1'b1;
        a_b     <= 1'b0;
        d_c     <= 1'b0;
        @(posedge clk);
    end
endtask

//============================================================================
// High-level register access tasks
//   Z8530 reg addressing: bits[2:0] = register (0-7), bit[3] = Point High (8-15)
//============================================================================

task write_ctrl;
    input        channel_a;
    input [3:0]  reg_num;
    input [7:0]  data;
    reg   [7:0]  ptr_cmd;
    begin
        if (reg_num != 0) begin
            ptr_cmd = (reg_num >= 8)
                      ? {4'b0000, 1'b1, reg_num[2:0]}    // Point High
                      : {5'b00000,       reg_num[2:0]};
            bus_write(channel_a, 1'b0, ptr_cmd);
        end
        bus_write(channel_a, 1'b0, data);
    end
endtask

task write_data;
    input        channel_a;
    input [7:0]  data;
    begin
        bus_write(channel_a, 1'b1, data);
    end
endtask

task read_ctrl;
    input        channel_a;
    input [3:0]  reg_num;
    output [7:0] data;
    reg   [7:0]  ptr_cmd;
    begin
        if (reg_num != 0) begin
            ptr_cmd = (reg_num >= 8)
                      ? {4'b0000, 1'b1, reg_num[2:0]}
                      : {5'b00000,       reg_num[2:0]};
            bus_write(channel_a, 1'b0, ptr_cmd);
        end
        bus_read(channel_a, 1'b0, data);
    end
endtask

task read_data;
    input        channel_a;
    output [7:0] data;
    begin
        bus_read(channel_a, 1'b1, data);
    end
endtask

//============================================================================
// External serial byte injector
//   Drives rxda/rxdb with start + 8 data bits (LSB first) + stop, using
//   absolute-time bit periods matched to the DUT's BRG-derived baud. Channel
//   A is clocked from pclk (4 MHz -> 41667 baud, 24 us/bit); Channel B from
//   sclk (3.6864 MHz -> 38400 baud, 26042 ns/bit).
//============================================================================

task send_serial_byte;
    input        channel_a;
    input [7:0]  byte_data;
    integer      i;
    integer      bt;
    begin
        bt = channel_a ? BIT_TIME_A_NS : BIT_TIME_NS;
        // Start bit
        if (channel_a) rxda = 1'b0; else rxdb = 1'b0;
        #(bt);
        // Data bits (LSB first)
        for (i = 0; i < 8; i = i + 1) begin
            if (channel_a) rxda = byte_data[i]; else rxdb = byte_data[i];
            #(bt);
        end
        // Stop bit
        if (channel_a) rxda = 1'b1; else rxdb = 1'b1;
        #(bt);
    end
endtask

//============================================================================
// Test sequence
//============================================================================

reg [7:0] read_val;
integer   i;

initial begin
    $display("===========================================");
    $display("Z8530 SCC Testbench - dual-clock, new bus");
    $display("===========================================");

    // Init signals
    reset_n  = 0;
    cs_n     = 1;
    rd_n     = 1;
    wr_n     = 1;
    a_b      = 1;
    d_c      = 0;
    data_in  = 8'h00;
    intack_n = 1;
    rxda     = 1;  rxdb = 1;
    rxca     = 0;  txca = 0;
    rxcb     = 0;  txcb = 0;          // external clocks tied to 0 (BRG-only)
    ctsa_n   = 0;  dcda_n = 0;  synca_n = 1;   // /SYNC deasserted (high) at start
    ctsb_n   = 0;  dcdb_n = 0;  syncb_n = 1;

    // Reset
    repeat(20) @(posedge clk);
    reset_n = 1;
    repeat(20) @(posedge clk);

    $display("[%0t] Reset complete", $time);

    //------------------------------------------------------------------------
    // Test 1: Configure Channel A for async 8N1
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 1: Configure Channel A", $time);
    write_ctrl(1, 4'd4, 8'h44);   // x16 clock, 1 stop, no parity
    write_ctrl(1, 4'd3, 8'hC1);   // RX 8 bits, RX enable
    write_ctrl(1, 4'd5, 8'h6A);   // TX 8 bits, TX enable, RTS
    write_ctrl(1, 4'd11, 8'h00);  // clocks from TRxC pins (will switch to BRG later)
    write_ctrl(1, 4'd1, 8'h00);   // no interrupts yet
    read_ctrl(1, 4'd0, read_val);
    $display("[%0t] RR0 = %02h (TX Empty=%b, CTS=%b, DCD=%b)",
             $time, read_val, read_val[2], read_val[5], read_val[3]);

    //------------------------------------------------------------------------
    // Test 2: TX a byte on Channel A (currently unclocked - no transmission)
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 2: Transmit byte 0x55 on Channel A (no clock yet)", $time);
    write_data(1, 8'h55);
    repeat(2000) @(posedge clk);
    read_ctrl(1, 4'd0, read_val);
    $display("[%0t] After TX (no BRG yet): RR0 = %02h (TX Empty=%b)", $time, read_val, read_val[2]);

    //------------------------------------------------------------------------
    // Test 3: Configure Channel B
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 3: Configure Channel B", $time);
    write_ctrl(0, 4'd4, 8'h44);
    write_ctrl(0, 4'd3, 8'hC1);
    write_ctrl(0, 4'd5, 8'h6A);
    read_ctrl(0, 4'd0, read_val);
    $display("[%0t] Channel B RR0 = %02h", $time, read_val);

    //------------------------------------------------------------------------
    // Test 4: Enable interrupts
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 4: Enable Master Interrupt", $time);
    write_ctrl(1, 4'd9, 8'h08);   // MIE
    write_ctrl(1, 4'd1, 8'h02);   // TX int enable
    read_ctrl(1, 4'd3, read_val);
    $display("[%0t] RR3 (Int Pending) = %02h", $time, read_val);

    //------------------------------------------------------------------------
    // Test 5: BRG configuration readback (TC=1 -> 38400 baud at x16)
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 5: Configure BRG (TC=1 -> 38400 baud)", $time);
    write_ctrl(1, 4'd12, 8'h01);  // TC low
    write_ctrl(1, 4'd13, 8'h00);  // TC high
    write_ctrl(1, 4'd14, 8'h01);  // BRG enable
    read_ctrl(1, 4'd12, read_val);
    $display("[%0t] RR12 = %02h (expected 01)", $time, read_val);
    read_ctrl(1, 4'd13, read_val);
    $display("[%0t] RR13 = %02h (expected 00)", $time, read_val);

    //------------------------------------------------------------------------
    // Test 6: Loopback - Channel A
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 6: Loopback Mode on Channel A", $time);
    write_ctrl(1, 4'd4, 8'h44);   // x16, 1 stop, no parity
    write_ctrl(1, 4'd3, 8'hC1);   // RX 8 bits, RX enable
    write_ctrl(1, 4'd5, 8'h6A);   // TX 8 bits, TX enable, RTS
    write_ctrl(1, 4'd12, 8'h01);  // BRG TC = 1 (38400 baud)
    write_ctrl(1, 4'd13, 8'h00);
    write_ctrl(1, 4'd11, 8'h50);  // TX/RX clocks from BRG
    write_ctrl(1, 4'd14, 8'h11);  // BRG enable + Loopback
    repeat(100) @(posedge clk);

    write_data(1, 8'hA5);
    $display("[%0t] Sent 0xA5 via TX (loopback)", $time);
    repeat(FRAME_WAIT_CLK) @(posedge clk);
    read_ctrl(1, 4'd0, read_val);
    $display("[%0t] RR0 = %02h (RX Avail=%b)", $time, read_val, read_val[0]);
    if (read_val[0]) begin
        read_data(1, read_val);
        if (read_val == 8'hA5)
            $display("[%0t] LOOPBACK PASS: Received 0x%02h", $time, read_val);
        else
            $display("[%0t] LOOPBACK FAIL: Received 0x%02h (expected 0xA5)", $time, read_val);
    end else
        $display("[%0t] LOOPBACK FAIL: No data received", $time);

    write_data(1, 8'h5A);
    $display("[%0t] Sent 0x5A via TX (loopback)", $time);
    repeat(FRAME_WAIT_CLK) @(posedge clk);
    read_ctrl(1, 4'd0, read_val);
    if (read_val[0]) begin
        read_data(1, read_val);
        if (read_val == 8'h5A)
            $display("[%0t] LOOPBACK PASS: Received 0x%02h", $time, read_val);
        else
            $display("[%0t] LOOPBACK FAIL: Received 0x%02h (expected 0x5A)", $time, read_val);
    end else
        $display("[%0t] LOOPBACK FAIL: No data received", $time);

    write_ctrl(1, 4'd14, 8'h01);   // Loopback off, BRG still on
    $display("[%0t] Loopback disabled", $time);

    //------------------------------------------------------------------------
    // Test 7: Loopback - Channel B
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 7: Loopback Mode on Channel B", $time);
    write_ctrl(0, 4'd4, 8'h44);
    write_ctrl(0, 4'd3, 8'hC1);
    write_ctrl(0, 4'd5, 8'h6A);
    write_ctrl(0, 4'd12, 8'h01);
    write_ctrl(0, 4'd13, 8'h00);
    write_ctrl(0, 4'd11, 8'h50);
    write_ctrl(0, 4'd14, 8'h11);
    repeat(100) @(posedge clk);

    write_data(0, 8'h3C);
    $display("[%0t] Sent 0x3C via Channel B TX (loopback)", $time);
    repeat(FRAME_WAIT_CLK) @(posedge clk);
    read_ctrl(0, 4'd0, read_val);
    if (read_val[0]) begin
        read_data(0, read_val);
        if (read_val == 8'h3C)
            $display("[%0t] CH-B LOOPBACK PASS: Received 0x%02h", $time, read_val);
        else
            $display("[%0t] CH-B LOOPBACK FAIL: Received 0x%02h (expected 0x3C)", $time, read_val);
    end else
        $display("[%0t] CH-B LOOPBACK FAIL: No data received", $time);

    write_ctrl(0, 4'd14, 8'h00);   // Disable BRG and loopback
    write_ctrl(0, 4'd3, 8'hC0);    // Disable RX
    write_ctrl(0, 4'd5, 8'h62);    // Disable TX
    $display("[%0t] Channel B fully disabled", $time);

    //------------------------------------------------------------------------
    // Test 8: Interrupt test (loopback)
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 8: Interrupt Test", $time);
    write_ctrl(1, 4'd4, 8'h44);
    write_ctrl(1, 4'd3, 8'hC1);
    write_ctrl(1, 4'd5, 8'h6A);
    write_ctrl(1, 4'd12, 8'h01);
    write_ctrl(1, 4'd13, 8'h00);
    write_ctrl(1, 4'd11, 8'h50);
    write_ctrl(1, 4'd14, 8'h11);
    write_ctrl(1, 4'd9, 8'h08);    // MIE
    write_ctrl(1, 4'd1, 8'h12);    // RX int on all chars + TX int enable
    $display("[%0t] Interrupts enabled (WR1=0x12)", $time);

    read_ctrl(1, 4'd3, read_val);
    $display("[%0t] RR3 (initial) = %02h, INT_N=%b", $time, read_val, int_n);

    write_data(1, 8'hBB);
    $display("[%0t] Sent 0xBB via loopback", $time);
    repeat(FRAME_WAIT_CLK) @(posedge clk);

    read_ctrl(1, 4'd3, read_val);
    $display("[%0t] RR3 after loopback = %02h, INT_N=%b", $time, read_val, int_n);
    if (read_val[5]) $display("[%0t] RX int pending (bit 5 set) PASS", $time);
    else             $display("[%0t] RX int NOT pending (RR3=%02h)", $time, read_val);
    if (read_val[4]) $display("[%0t] TX int pending (bit 4 set) PASS", $time);
    else             $display("[%0t] TX int NOT pending (RR3=%02h)", $time, read_val);

    write_ctrl(1, 4'd0, 8'h28);    // Reset TX int pending
    $display("[%0t] WR0 = 0x28 (Reset TX int pending)", $time);

    read_ctrl(0, 4'd2, read_val);
    $display("[%0t] RR2 (Interrupt Vector) = %02h", $time, read_val);

    read_ctrl(1, 4'd0, read_val);
    if (read_val[0]) begin
        read_data(1, read_val);
        $display("[%0t] Read RX data 0x%02h", $time, read_val);
    end

    read_ctrl(1, 4'd3, read_val);
    $display("[%0t] RR3 after reading data = %02h (should be 0)", $time, read_val);

    write_ctrl(1, 4'd1, 8'h00);
    write_ctrl(1, 4'd9, 8'h00);
    $display("[%0t] Interrupts disabled, INT_N=%b", $time, int_n);

    write_ctrl(1, 4'd14, 8'h01);   // Loopback off, BRG still on
    // Flush
    read_ctrl(1, 4'd0, read_val);
    while (read_val[0]) begin
        read_data(1, read_val);
        read_ctrl(1, 4'd0, read_val);
    end
    $display("[%0t] RX FIFO flushed", $time);

    //------------------------------------------------------------------------
    // Test 9: Loopback stress - 512 random bytes on Channel A
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 9: Loopback stress - 512 random bytes (Ch A)", $time);
    write_ctrl(1, 4'd4, 8'h44);
    write_ctrl(1, 4'd3, 8'hC1);
    write_ctrl(1, 4'd5, 8'h6A);
    write_ctrl(1, 4'd12, 8'h01);
    write_ctrl(1, 4'd13, 8'h00);
    write_ctrl(1, 4'd11, 8'h50);
    write_ctrl(1, 4'd14, 8'h11);
    repeat(100) @(posedge clk);

    begin : loopback_stress_a
        reg [7:0] tx_data [0:511];
        reg [7:0] rx_data;
        reg [31:0] seed;
        integer tx_count, rx_count, errors;
        integer tx_idx, rx_idx;
        integer timeout_cnt;
        integer in_flight;

        seed        = 32'hDEADBEEF;
        errors      = 0;
        tx_count    = 0;
        rx_count    = 0;
        tx_idx      = 0;
        rx_idx      = 0;
        timeout_cnt = 0;

        for (i = 0; i < 512; i = i + 1) begin
            seed = seed * 1103515245 + 12345;
            tx_data[i] = seed[15:8];
        end

        $display("[%0t] Starting 512-byte loopback...", $time);

        while (rx_count < 512) begin
            read_ctrl(1, 4'd0, read_val);
            while (read_val[0] && rx_count < 512) begin
                read_data(1, rx_data);
                if (rx_data !== tx_data[rx_idx]) begin
                    if (errors < 10)
                        $display("[%0t] ERROR byte %0d: sent %02h got %02h",
                                 $time, rx_idx, tx_data[rx_idx], rx_data);
                    errors = errors + 1;
                end
                rx_count = rx_count + 1;
                rx_idx   = rx_idx + 1;
                read_ctrl(1, 4'd0, read_val);
            end

            in_flight = tx_count - rx_count;
            if (read_val[2] && tx_count < 512 && in_flight < 2) begin
                write_data(1, tx_data[tx_idx]);
                tx_count = tx_count + 1;
                tx_idx   = tx_idx + 1;
            end

            repeat(500) @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (timeout_cnt > 200000) begin
                $display("[%0t] TIMEOUT! tx=%0d rx=%0d", $time, tx_count, rx_count);
                errors   = errors + 1;
                rx_count = 512;
            end
        end

        if (errors == 0) $display("[%0t] STRESS PASS (Ch A)", $time);
        else             $display("[%0t] STRESS FAIL (Ch A): %0d errors", $time, errors);
    end

    write_ctrl(1, 4'd14, 8'h01);   // loopback off

    //------------------------------------------------------------------------
    // Test 10: Loopback stress - 512 random bytes on Channel B
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 10: Loopback stress - 512 random bytes (Ch B)", $time);
    read_ctrl(0, 4'd0, read_val);
    while (read_val[0]) begin
        read_data(0, read_val);
        read_ctrl(0, 4'd0, read_val);
    end
    repeat(100) @(posedge clk);

    write_ctrl(0, 4'd14, 8'h00);
    write_ctrl(0, 4'd4, 8'h44);
    write_ctrl(0, 4'd3, 8'hC1);
    write_ctrl(0, 4'd5, 8'h6A);
    write_ctrl(0, 4'd12, 8'h01);
    write_ctrl(0, 4'd13, 8'h00);
    write_ctrl(0, 4'd11, 8'h50);
    write_ctrl(0, 4'd14, 8'h11);
    repeat(100) @(posedge clk);

    begin : loopback_stress_b
        reg [7:0] tx_data_b [0:511];
        reg [7:0] rx_data_b;
        reg [31:0] seed_b;
        integer tx_count_b, rx_count_b, errors_b;
        integer tx_idx_b, rx_idx_b;
        integer timeout_cnt_b;
        integer in_flight_b;

        seed_b        = 32'hCAFEBABE;
        errors_b      = 0;
        tx_count_b    = 0;
        rx_count_b    = 0;
        tx_idx_b      = 0;
        rx_idx_b      = 0;
        timeout_cnt_b = 0;

        for (i = 0; i < 512; i = i + 1) begin
            seed_b = seed_b * 1103515245 + 12345;
            tx_data_b[i] = seed_b[15:8];
        end

        $display("[%0t] Starting 512-byte loopback (Ch B)...", $time);

        while (rx_count_b < 512) begin
            read_ctrl(0, 4'd0, read_val);
            while (read_val[0] && rx_count_b < 512) begin
                read_data(0, rx_data_b);
                if (rx_data_b !== tx_data_b[rx_idx_b]) begin
                    if (errors_b < 10)
                        $display("[%0t] ERROR Ch-B byte %0d: sent %02h got %02h",
                                 $time, rx_idx_b, tx_data_b[rx_idx_b], rx_data_b);
                    errors_b = errors_b + 1;
                end
                rx_count_b = rx_count_b + 1;
                rx_idx_b   = rx_idx_b + 1;
                read_ctrl(0, 4'd0, read_val);
            end

            in_flight_b = tx_count_b - rx_count_b;
            if (read_val[2] && tx_count_b < 512 && in_flight_b < 2) begin
                write_data(0, tx_data_b[tx_idx_b]);
                tx_count_b = tx_count_b + 1;
                tx_idx_b   = tx_idx_b + 1;
            end

            repeat(500) @(posedge clk);
            timeout_cnt_b = timeout_cnt_b + 1;
            if (timeout_cnt_b > 200000) begin
                $display("[%0t] TIMEOUT Ch-B! tx=%0d rx=%0d", $time, tx_count_b, rx_count_b);
                errors_b   = errors_b + 1;
                rx_count_b = 512;
            end
        end

        if (errors_b == 0) $display("[%0t] STRESS PASS (Ch B)", $time);
        else               $display("[%0t] STRESS FAIL (Ch B): %0d errors", $time, errors_b);
    end

    write_ctrl(0, 4'd14, 8'h01);

    //------------------------------------------------------------------------
    // Test 12: XON/XOFF software flow control
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 12: XON/XOFF Software Flow Control", $time);

    begin : xon_xoff_test
        reg [7:0] xrx;
        reg       flow_stopped;
        integer   errs;

        errs         = 0;
        flow_stopped = 0;

        // Part A: loopback round-trip
        $display("[%0t] Part A: loopback XON/XOFF round-trip", $time);
        write_ctrl(1, 4'd14, 8'h00);
        write_ctrl(1, 4'd4, 8'h44);
        write_ctrl(1, 4'd3, 8'hC1);
        write_ctrl(1, 4'd5, 8'h6A);
        write_ctrl(1, 4'd12, 8'h01);
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);
        write_ctrl(1, 4'd14, 8'h11);
        repeat(100) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h13);                                  // XOFF
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h13) $display("[%0t] XOFF round-trip PASS (%02h)", $time, xrx);
            else begin
                $display("[%0t] XOFF round-trip FAIL (%02h)", $time, xrx);
                errs = errs + 1;
            end
        end else begin
            $display("[%0t] XOFF round-trip FAIL: no data", $time);
            errs = errs + 1;
        end

        write_data(1, 8'h11);                                  // XON
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h11) $display("[%0t] XON round-trip PASS (%02h)", $time, xrx);
            else begin
                $display("[%0t] XON round-trip FAIL (%02h)", $time, xrx);
                errs = errs + 1;
            end
        end else begin
            $display("[%0t] XON round-trip FAIL: no data", $time);
            errs = errs + 1;
        end

        // Part B: pause/resume pattern
        $display("[%0t] Part B: SW flow-control pause/resume", $time);
        write_data(1, 8'hAA);
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'hAA) $display("[%0t] Pre-XOFF PASS (%02h)", $time, xrx);
            else begin $display("[%0t] Pre-XOFF FAIL (%02h)", $time, xrx); errs = errs + 1; end
        end else begin $display("[%0t] Pre-XOFF FAIL: no data", $time); errs = errs + 1; end

        write_data(1, 8'h13);
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h13) begin flow_stopped = 1; $display("[%0t] XOFF -> paused", $time); end
            else begin $display("[%0t] XOFF FAIL (%02h)", $time, xrx); errs = errs + 1; end
        end

        repeat(2000) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (!read_val[0] && flow_stopped)
            $display("[%0t] PAUSE PASS (no data while stopped)", $time);

        write_data(1, 8'h11);
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h11) begin flow_stopped = 0; $display("[%0t] XON -> resumed", $time); end
            else begin $display("[%0t] XON FAIL (%02h)", $time, xrx); errs = errs + 1; end
        end

        write_data(1, 8'h55);
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h55) $display("[%0t] Post-XON PASS (%02h)", $time, xrx);
            else begin $display("[%0t] Post-XON FAIL (%02h)", $time, xrx); errs = errs + 1; end
        end

        // Part C: external serial RX of XON/XOFF (still using BRG-clocked RX
        // since external rxca is tied to 0; the data line itself is driven by
        // the TB at the matching baud rate).
        $display("[%0t] Part C: External RX serial XON/XOFF", $time);
        write_ctrl(1, 4'd14, 8'h01);   // loopback off, BRG still on

        send_serial_byte(1, 8'h13);
        repeat(FRAME_WAIT_CLK/2) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h13) $display("[%0t] EXT XOFF PASS (%02h)", $time, xrx);
            else begin $display("[%0t] EXT XOFF FAIL (%02h)", $time, xrx); errs = errs + 1; end
        end else begin $display("[%0t] EXT XOFF FAIL: no data", $time); errs = errs + 1; end

        send_serial_byte(1, 8'h11);
        repeat(FRAME_WAIT_CLK/2) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) begin
            read_data(1, xrx);
            if (xrx == 8'h11) $display("[%0t] EXT XON PASS (%02h)", $time, xrx);
            else begin $display("[%0t] EXT XON FAIL (%02h)", $time, xrx); errs = errs + 1; end
        end else begin $display("[%0t] EXT XON FAIL: no data", $time); errs = errs + 1; end

        // Part D: mixed stream
        $display("[%0t] Part D: Mixed stream DE/13/AD/11/BE", $time);
        write_ctrl(1, 4'd14, 8'h11);   // loopback on
        repeat(100) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        begin : mixed
            reg [7:0] seq [0:4];
            reg [7:0] rx_byte;
            integer   k, m_errs;
            reg       m_stopped;
            seq[0]=8'hDE; seq[1]=8'h13; seq[2]=8'hAD; seq[3]=8'h11; seq[4]=8'hBE;
            m_errs = 0; m_stopped = 0;
            for (k=0; k<5; k=k+1) begin
                write_data(1, seq[k]);
                repeat(FRAME_WAIT_CLK) @(posedge clk);
                read_ctrl(1, 4'd0, read_val);
                if (read_val[0]) begin
                    read_data(1, rx_byte);
                    if (rx_byte !== seq[k]) begin
                        $display("[%0t] MIXED byte %0d got %02h (exp %02h)",
                                 $time, k, rx_byte, seq[k]);
                        m_errs = m_errs + 1;
                    end
                    if      (rx_byte == 8'h13) m_stopped = 1;
                    else if (rx_byte == 8'h11) m_stopped = 0;
                end else begin
                    $display("[%0t] MIXED byte %0d: no data", $time, k);
                    m_errs = m_errs + 1;
                end
            end
            if (m_errs == 0) $display("[%0t] MIXED STREAM PASS", $time);
            else             $display("[%0t] MIXED STREAM FAIL: %0d errs", $time, m_errs);
            errs = errs + m_errs;
        end

        if (errs == 0) $display("[%0t] XON/XOFF TEST PASS", $time);
        else           $display("[%0t] XON/XOFF TEST FAIL: %0d errs", $time, errs);
    end

    write_ctrl(1, 4'd14, 8'h01);   // loopback off

    //------------------------------------------------------------------------
    // Test 13: "Hello world!" on Channel A and B via loopback
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 13: \"Hello world!\" on Channel A & B", $time);

    begin : hello
        reg [7:0] str [0:11];
        reg [7:0] rch;
        integer   k, errs_a, errs_b;

        str[0]="H"; str[1]="e"; str[2]="l"; str[3]="l"; str[4]="o"; str[5]=" ";
        str[6]="w"; str[7]="o"; str[8]="r"; str[9]="l"; str[10]="d"; str[11]="!";
        errs_a = 0; errs_b = 0;

        // -- Ch A --
        $display("[%0t] Ch A: sending \"Hello world!\"", $time);
        write_ctrl(1, 4'd14, 8'h00);
        write_ctrl(1, 4'd4, 8'h44);
        write_ctrl(1, 4'd3, 8'hC1);
        write_ctrl(1, 4'd5, 8'h6A);
        write_ctrl(1, 4'd12, 8'h01);
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);
        write_ctrl(1, 4'd14, 8'h11);
        repeat(100) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        for (k=0; k<12; k=k+1) begin
            write_data(1, str[k]);
            repeat(FRAME_WAIT_CLK) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin
                read_data(1, rch);
                if (rch !== str[k]) begin
                    $display("[%0t] Ch-A char %0d got %02h (exp %02h '%c')",
                             $time, k, rch, str[k], str[k]);
                    errs_a = errs_a + 1;
                end
            end else begin
                $display("[%0t] Ch-A char %0d: no data ('%c')", $time, k, str[k]);
                errs_a = errs_a + 1;
            end
        end

        // Print collected string
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end
        begin : cha_print
            reg [8*12-1:0] s;
            integer p;
            s = 0;
            for (p=0; p<12; p=p+1) begin
                write_data(1, str[p]);
                repeat(FRAME_WAIT_CLK) @(posedge clk);
                read_ctrl(1, 4'd0, read_val);
                if (read_val[0]) begin
                    read_data(1, rch);
                    s = {s[8*11-1:0], rch};
                end else begin
                    s = {s[8*11-1:0], 8'h3F};
                end
            end
            $display("[%0t] Ch-A received: \"%s\"", $time, s);
        end
        if (errs_a == 0) $display("[%0t] Ch-A HELLO WORLD PASS", $time);
        else             $display("[%0t] Ch-A HELLO WORLD FAIL: %0d errs", $time, errs_a);
        write_ctrl(1, 4'd14, 8'h01);

        // -- Ch B --
        $display("\n[%0t] Ch B: sending \"Hello world!\"", $time);
        write_ctrl(0, 4'd14, 8'h00);
        write_ctrl(0, 4'd4, 8'h44);
        write_ctrl(0, 4'd3, 8'hC1);
        write_ctrl(0, 4'd5, 8'h6A);
        write_ctrl(0, 4'd12, 8'h01);
        write_ctrl(0, 4'd13, 8'h00);
        write_ctrl(0, 4'd11, 8'h50);
        write_ctrl(0, 4'd14, 8'h11);
        repeat(100) @(posedge clk);
        read_ctrl(0, 4'd0, read_val);
        while (read_val[0]) begin read_data(0, read_val); read_ctrl(0, 4'd0, read_val); end

        for (k=0; k<12; k=k+1) begin
            write_data(0, str[k]);
            repeat(FRAME_WAIT_CLK) @(posedge clk);
            read_ctrl(0, 4'd0, read_val);
            if (read_val[0]) begin
                read_data(0, rch);
                if (rch !== str[k]) begin
                    $display("[%0t] Ch-B char %0d got %02h (exp %02h '%c')",
                             $time, k, rch, str[k], str[k]);
                    errs_b = errs_b + 1;
                end
            end else begin
                $display("[%0t] Ch-B char %0d: no data ('%c')", $time, k, str[k]);
                errs_b = errs_b + 1;
            end
        end

        read_ctrl(0, 4'd0, read_val);
        while (read_val[0]) begin read_data(0, read_val); read_ctrl(0, 4'd0, read_val); end
        begin : chb_print
            reg [8*12-1:0] s;
            integer p;
            s = 0;
            for (p=0; p<12; p=p+1) begin
                write_data(0, str[p]);
                repeat(FRAME_WAIT_CLK) @(posedge clk);
                read_ctrl(0, 4'd0, read_val);
                if (read_val[0]) begin
                    read_data(0, rch);
                    s = {s[8*11-1:0], rch};
                end else begin
                    s = {s[8*11-1:0], 8'h3F};
                end
            end
            $display("[%0t] Ch-B received: \"%s\"", $time, s);
        end
        if (errs_b == 0) $display("[%0t] Ch-B HELLO WORLD PASS", $time);
        else             $display("[%0t] Ch-B HELLO WORLD FAIL: %0d errs", $time, errs_b);
        write_ctrl(0, 4'd14, 8'h01);
    end

    //------------------------------------------------------------------------
    // Test 14: Extended Interrupt Coverage
    //   A) MIE gating
    //   B) Ext/Status interrupt from CTS edge (Ch A)
    //   C) Ext/Status interrupt from DCD edge (Ch B)
    //   D) RR2 interrupt vector with/without VIS
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 14: Extended Interrupt Coverage", $time);

    begin : int_extra
        integer errs;
        errs = 0;

        // ---- Sub-test A: MIE gating ----
        $display("[%0t] A: MIE gating", $time);
        // Make sure everything starts disabled
        write_ctrl(1, 4'd14, 8'h00);
        write_ctrl(1, 4'd9,  8'h00);   // MIE=0
        write_ctrl(1, 4'd1,  8'h02);   // TX int enable
        write_ctrl(1, 4'd4,  8'h44);
        write_ctrl(1, 4'd3,  8'hC1);
        write_ctrl(1, 4'd5,  8'h6A);
        write_ctrl(1, 4'd12, 8'h01);
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);
        write_ctrl(1, 4'd14, 8'h11);   // BRG + loopback
        repeat(100) @(posedge clk);

        // Clear any leftover ints
        write_ctrl(1, 4'd0, 8'h28);    // reset TX int pending
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end
        repeat(20) @(posedge clk);

        write_data(1, 8'h77);
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd3, read_val);
        if (read_val[4]) $display("[%0t]   TX int pending after TX (RR3=%02h)", $time, read_val);
        else begin
            $display("[%0t]   FAIL: TX int not pending (RR3=%02h)", $time, read_val);
            errs = errs + 1;
        end
        if (int_n)
            $display("[%0t]   INT_N high w/ MIE=0 PASS", $time);
        else begin
            $display("[%0t]   FAIL: INT_N low with MIE=0", $time);
            errs = errs + 1;
        end

        // Turn MIE on - INT_N should immediately drop
        write_ctrl(1, 4'd9, 8'h08);
        repeat(20) @(posedge clk);
        if (!int_n)
            $display("[%0t]   INT_N asserted after MIE PASS", $time);
        else begin
            $display("[%0t]   FAIL: INT_N still high after MIE", $time);
            errs = errs + 1;
        end

        // Clear and drain
        write_ctrl(1, 4'd0, 8'h28);
        read_ctrl(1, 4'd0, read_val);
        if (read_val[0]) read_data(1, read_val);
        repeat(20) @(posedge clk);

        // ---- Sub-test B: Ext/Status int from CTS edge (Ch A) ----
        $display("[%0t] B: Ext/Status int from CTS (Ch A)", $time);
        write_ctrl(1, 4'd9,  8'h08);   // MIE
        write_ctrl(1, 4'd1,  8'h01);   // Ext int enable (WR1[0])
        write_ctrl(1, 4'd15, 8'h20);   // CTS IE  (WR15[5])
        write_ctrl(1, 4'd0,  8'h10);   // Reset ext/status pending (clear any startup edge)
        repeat(50) @(posedge clk);     // let sync chain settle
        read_ctrl(1, 4'd3, read_val);
        if (!read_val[3] && int_n)
            $display("[%0t]   Initial state clean (RR3=%02h, INT_N=%b)", $time, read_val, int_n);

        ctsa_n = 1'b1;                 // CTS deassert (active-low transition)
        repeat(50) @(posedge clk);     // wait for 3-FF sync + edge detect
        read_ctrl(1, 4'd3, read_val);
        if (read_val[3])
            $display("[%0t]   Ext int A pending PASS (RR3=%02h)", $time, read_val);
        else begin
            $display("[%0t]   FAIL: Ext int A not pending (RR3=%02h)", $time, read_val);
            errs = errs + 1;
        end
        if (!int_n)
            $display("[%0t]   INT_N asserted PASS", $time);
        else begin
            $display("[%0t]   FAIL: INT_N not asserted", $time);
            errs = errs + 1;
        end

        // Clear via WR0 = 0x10 (cmd 010 in bits[5:3])
        write_ctrl(1, 4'd0, 8'h10);
        repeat(20) @(posedge clk);
        read_ctrl(1, 4'd3, read_val);
        if (!read_val[3])
            $display("[%0t]   Ext int A cleared PASS", $time);
        else begin
            $display("[%0t]   FAIL: Ext int A still pending after WR0=0x10", $time);
            errs = errs + 1;
        end

        // ---- Sub-test C: Ext/Status int from DCD edge (Ch B) ----
        $display("[%0t] C: Ext/Status int from DCD (Ch B)", $time);
        write_ctrl(0, 4'd1,  8'h01);   // Ext int enable
        write_ctrl(0, 4'd15, 8'h08);   // DCD IE (WR15[3])
        write_ctrl(0, 4'd0,  8'h10);   // reset ext/status
        repeat(50) @(posedge clk);

        dcdb_n = 1'b1;                 // DCD edge
        repeat(50) @(posedge clk);
        read_ctrl(1, 4'd3, read_val);  // RR3 always from Ch A (chip-wide register)
        if (read_val[0])
            $display("[%0t]   Ext int B pending PASS (RR3=%02h)", $time, read_val);
        else begin
            $display("[%0t]   FAIL: Ext int B not pending (RR3=%02h)", $time, read_val);
            errs = errs + 1;
        end

        write_ctrl(0, 4'd0, 8'h10);
        repeat(20) @(posedge clk);
        read_ctrl(1, 4'd3, read_val);
        if (!read_val[0])
            $display("[%0t]   Ext int B cleared PASS", $time);
        else begin
            $display("[%0t]   FAIL: Ext int B still pending", $time);
            errs = errs + 1;
        end

        // ---- Sub-test D: RR2 interrupt vector ----
        // Per Z8530 datasheet: RR2 read via Ch A always returns the raw vector;
        // RR2 read via Ch B always returns the status-modified vector. VIS
        // (WR9[0]) does NOT gate normal RR2 reads -- it gates only the
        // INTACK-cycle vector, which this model doesn't implement.
        $display("[%0t] D: RR2 interrupt vector", $time);
        write_ctrl(1, 4'd2, 8'hAB);    // base vector in Ch A WR2
        write_ctrl(1, 4'd9, 8'h08);    // MIE=1, VIS=0 (must be irrelevant for RR2 reads)
        write_ctrl(1, 4'd1, 8'h02);    // TX int enable
        write_ctrl(1, 4'd0, 8'h28);    // clear any prior TX int
        repeat(20) @(posedge clk);

        // RR2 via Ch A: always raw vector
        read_ctrl(1, 4'd2, read_val);
        if (read_val == 8'hAB)
            $display("[%0t]   RR2_a (Ch A) = %02h raw PASS", $time, read_val);
        else begin
            $display("[%0t]   FAIL: RR2_a = %02h (exp AB)", $time, read_val);
            errs = errs + 1;
        end

        // Generate a TX int, then read RR2_b -- should reflect modified status
        // even with VIS=0 (datasheet: status always included on Ch B).
        write_data(1, 8'h99);
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(0, 4'd2, read_val);
        $display("[%0t]   RR2_b (Ch B) w/ TX-A int = %02h (base AB)", $time, read_val);
        // With WR9[4]=0 (status low position), int_status replaces bits [3:1].
        // For TX-A int_status = 3'b100, so vector = AB[7:4]_100_AB[0] = 1010_100_1 = 0xA9
        if (read_val == 8'hA9)
            $display("[%0t]   RR2_b status-modified PASS", $time);
        else begin
            $display("[%0t]   FAIL: RR2_b = %02h (exp A9)", $time, read_val);
            errs = errs + 1;
        end

        // Cleanup
        write_ctrl(1, 4'd0,  8'h28);   // clear TX int
        write_ctrl(1, 4'd14, 8'h01);   // loopback off
        write_ctrl(1, 4'd9,  8'h00);
        write_ctrl(1, 4'd1,  8'h00);
        write_ctrl(0, 4'd1,  8'h00);
        write_ctrl(1, 4'd15, 8'h00);
        write_ctrl(0, 4'd15, 8'h00);
        ctsa_n = 1'b0;
        dcdb_n = 1'b0;
        repeat(50) @(posedge clk);
        // Clear residual ext-status from the de-assertion edges
        write_ctrl(1, 4'd0, 8'h10);
        write_ctrl(0, 4'd0, 8'h10);

        // ---- Summary ----
        if (errs == 0) $display("[%0t] INTERRUPT TEST PASS (%0d sub-tests)", $time, 4);
        else           $display("[%0t] INTERRUPT TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 15: BREAK round-trip via loopback
    //   A) Send Break (WR5[4]) drives txda low
    //   B) RX detector raises RR0[7] after one full character frame
    //   C) Ext/Status int fires when WR15[7] enabled
    //   D) Clearing Send Break lets RR0[7] go back to 0 and re-fires ext int
    //   E) WR0 error-reset (cmd 110) clears RR0[7] mid-break
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 15: BREAK round-trip", $time);

    begin : break_test
        integer errs;
        errs = 0;

        // Channel A loopback at 38400 baud
        write_ctrl(1, 4'd14, 8'h00);
        write_ctrl(1, 4'd4,  8'h44);
        write_ctrl(1, 4'd3,  8'hC1);
        write_ctrl(1, 4'd5,  8'h6A);   // TX/RX enable, RTS, NO Send Break
        write_ctrl(1, 4'd12, 8'h01);
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);
        write_ctrl(1, 4'd14, 8'h11);   // BRG + loopback
        write_ctrl(1, 4'd9,  8'h08);   // MIE
        write_ctrl(1, 4'd1,  8'h01);   // Ext/Status int enable
        write_ctrl(1, 4'd15, 8'h80);   // BREAK IE only (WR15[7])
        write_ctrl(1, 4'd0,  8'h10);   // clear any startup ext-status pending
        repeat(100) @(posedge clk);
        // Flush RX FIFO of any startup noise
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // --- Sub-test A: Send Break -> txda goes low ---
        $display("[%0t] A: Send Break", $time);
        write_ctrl(1, 4'd5, 8'h7A);    // 0x6A | 0x10 -> Send Break asserted
        repeat(200) @(posedge clk);    // let sclk-domain CDC catch up
        if (txda == 1'b0)
            $display("[%0t]   txda forced low PASS", $time);
        else begin
            $display("[%0t]   FAIL: txda = %b (expected 0)", $time, txda);
            errs = errs + 1;
        end

        // --- Sub-test B: wait for BREAK detection ---
        $display("[%0t] B: BREAK detect", $time);
        // Threshold = 11 bit-times @ 38400 baud = ~286 us = ~5720 cycles @ 20 MHz
        // FRAME_WAIT_CLK is 12000 -> generous, but BREAK detect uses rx_clk
        // sampling and the line must remain low past the threshold. Wait ~2 frames.
        repeat(FRAME_WAIT_CLK * 2) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        $display("[%0t]   RR0 = %02h (bit 7 = Break/Abort = %b)", $time, read_val, read_val[7]);
        if (read_val[7])
            $display("[%0t]   RR0[7] BREAK PASS", $time);
        else begin
            $display("[%0t]   FAIL: RR0[7] not set", $time);
            errs = errs + 1;
        end

        // --- Sub-test C: Ext/Status interrupt fires ---
        $display("[%0t] C: Ext/Status int from BREAK", $time);
        read_ctrl(1, 4'd3, read_val);
        $display("[%0t]   RR3 = %02h (Ext-A pending = bit 3 = %b), INT_N=%b",
                 $time, read_val, read_val[3], int_n);
        if (read_val[3])
            $display("[%0t]   Ext int A pending PASS", $time);
        else begin
            $display("[%0t]   FAIL: Ext int A not pending (RR3=%02h)", $time, read_val);
            errs = errs + 1;
        end
        if (!int_n)
            $display("[%0t]   INT_N asserted PASS", $time);
        else begin
            $display("[%0t]   FAIL: INT_N not asserted", $time);
            errs = errs + 1;
        end

        // Clear ext-status pending
        write_ctrl(1, 4'd0, 8'h10);
        repeat(20) @(posedge clk);

        // --- Sub-test D: Clear Send Break -> RR0[7] drops, new ext int fires ---
        $display("[%0t] D: End of BREAK (release Send Break)", $time);
        write_ctrl(1, 4'd5, 8'h6A);    // clear bit 4 -> Send Break off
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (!read_val[7])
            $display("[%0t]   RR0[7] cleared PASS (RR0=%02h)", $time, read_val);
        else begin
            $display("[%0t]   FAIL: RR0[7] still set (RR0=%02h)", $time, read_val);
            errs = errs + 1;
        end
        read_ctrl(1, 4'd3, read_val);
        if (read_val[3])
            $display("[%0t]   End-of-break Ext int PASS (RR3=%02h)", $time, read_val);
        else begin
            $display("[%0t]   FAIL: End-of-break Ext int not pending (RR3=%02h)",
                     $time, read_val);
            errs = errs + 1;
        end
        write_ctrl(1, 4'd0, 8'h10);    // clear
        repeat(20) @(posedge clk);

        // --- Sub-test E: WR0 error reset clears RR0[7] mid-break ---
        $display("[%0t] E: WR0 error-reset clears mid-break", $time);
        write_ctrl(1, 4'd5, 8'h7A);    // assert Send Break again
        repeat(FRAME_WAIT_CLK * 2) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (!read_val[7]) begin
            $display("[%0t]   Pre-check FAIL: RR0[7] not set before err-reset", $time);
            errs = errs + 1;
        end
        write_ctrl(1, 4'd0, 8'h30);    // cmd 110 (Error Reset) - bits[5:3]=110
        repeat(50) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (!read_val[7])
            $display("[%0t]   RR0[7] cleared by err-reset PASS (RR0=%02h)", $time, read_val);
        else begin
            // Note: line is still low, so detector will re-assert quickly.
            // Pass if we see at least a transient clear via reading immediately
            // after the command. Otherwise mark as a known limitation.
            $display("[%0t]   NOTE: RR0[7] still set after err-reset (line still low) RR0=%02h",
                     $time, read_val);
        end

        // Cleanup
        write_ctrl(1, 4'd5,  8'h6A);   // release Send Break
        write_ctrl(1, 4'd0,  8'h10);   // clear ext-status
        write_ctrl(1, 4'd14, 8'h01);   // loopback off
        write_ctrl(1, 4'd15, 8'h00);   // BREAK IE off
        write_ctrl(1, 4'd1,  8'h00);
        write_ctrl(1, 4'd9,  8'h00);
        repeat(100) @(posedge clk);

        if (errs == 0) $display("[%0t] BREAK TEST PASS", $time);
        else           $display("[%0t] BREAK TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 16: WR0 command-code register-pointer behavior
    //   Verifies that only command code 001 (Point High) sets reg_ptr[3].
    //   All other 7 command codes (000 Null, 010 Reset Ext/Stat, 011 Send
    //   Abort, 100 En Int Next RX, 101 Reset TX Int, 110 Error Reset,
    //   111 Reset IUS) must leave reg_ptr[3]=0 and select reg [2:0].
    //   Regression test for an earlier bug where bit 3 alone was used,
    //   wrongly re-pointing to regs 8-15 on Send Abort / Reset TX Int / IUS.
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 16: WR0 command-code reg_ptr decode", $time);

    begin : wr0_cmd_test
        integer errs;
        reg [7:0] sentinel;
        errs = 0;

        // Seed registers with known sentinels we can identify by readback.
        // Pick values whose RR mapping is unique enough to tell apart:
        //   WR2 = 0xAB  -> RR2_a returns 0xAB
        //   WR12 = 0x5C, WR13 = 0xC5 -> RR12 = 0x5C, RR13 = 0xC5
        // RR0 has live status fields so we check its low bits rather than full value.
        write_ctrl(1, 4'd2,  8'hAB);
        write_ctrl(1, 4'd12, 8'h5C);
        write_ctrl(1, 4'd13, 8'hC5);

        // -- After WR0 = 0x00 (Null cmd, bits [5:3]=000) reg_ptr should be 0 --
        bus_write(1, 1'b0, 8'h00);
        bus_read (1, 1'b0, sentinel);   // reads via current reg_ptr
        // RR0 bits 1 and 6 are guaranteed 0 in our config; just print and don't
        // hard-fail since live status changes. Sanity: read RR0 again via
        // read_ctrl to confirm path works.
        $display("[%0t]   WR0=0x00 (Null): read returned %02h (should be RR0)", $time, sentinel);

        // -- WR0 = 0x08 (Point High, [5:3]=001) reg_ptr should be 8 -> RR8 --
        bus_write(1, 1'b0, 8'h08);
        bus_read (1, 1'b0, sentinel);
        // RR8 = RX FIFO head (uninitialized after no RX) - just confirm it's
        // NOT 0xAB (WR2) or 0x5C/0xC5 (WR12/13). Best we can do without rxd.
        $display("[%0t]   WR0=0x08 (Point High): read returned %02h (should be RR8)",
                 $time, sentinel);

        // -- WR0 = 0x10 (Reset Ext/Stat, [5:3]=010) reg_ptr should go to 0 --
        // With the pointer at 0 (the prior RR8 read auto-reset it), writing
        // 0x10 is a genuine WR0 command with bits[2:0]=000, so the pointer must
        // stay at 0 and the next read returns RR0. (Pre-loading the pointer to a
        // non-zero reg would instead route 0x10 into that data reg, never
        // executing the command -- hence the read must be RR0-shaped, not RR2.)
        bus_write(1, 1'b0, 8'h10);     // cmd Reset Ext/Stat; ptr stays 0
        bus_read (1, 1'b0, sentinel);
        if (sentinel[6] == 1'b0 && sentinel[2] == 1'b1)
            $display("[%0t]   WR0=0x10 (Reset Ext/Stat): ptr->0 PASS (RR0=%02h)",
                     $time, sentinel);
        else begin
            $display("[%0t]   FAIL: WR0=0x10 ptr not 0 (read=%02h, not RR0-shaped)",
                     $time, sentinel);
            errs = errs + 1;
        end

        // -- WR0 = 0x18 (Send Abort, [5:3]=011) - bit 3 is set, but command
        //    code is NOT Point High. reg_ptr MUST be 0, not 8. --
        bus_write(1, 1'b0, 8'h18);     // command 011, bit 3 = 1
        bus_read (1, 1'b0, sentinel);
        // After cmd, reg_ptr should be 0 -> read returns RR0 (live status).
        // To make this a hard-fail check, verify we did NOT get an RR8-style
        // value. Reseed WR2 trick: point to 2, write 0x18, read.
        write_ctrl(1, 4'd2, 8'hAB);
        bus_write(1, 1'b0, 8'h02);     // ptr = 2
        bus_write(1, 1'b0, 8'h18);     // cmd Send Abort; ptr must end at 0 (datasheet) - but in this RTL the auto-reset path is via wr0[2:0] = 000
        bus_read (1, 1'b0, sentinel);
        if (sentinel == 8'hAB) begin
            // sentinel == RR2 means ptr went to 0 then... wait, RR0 isn't 0xAB.
            // Actually after cmd write, ptr decode = {001==001 ? 1 : 0, [2:0]=000} = 0.
            $display("[%0t]   UNEXPECTED: read=%02h after WR0=0x18 (RR2 sentinel)",
                     $time, sentinel);
        end
        // The decisive test: write 0x18 with bits [2:0] = 000. ptr must NOT
        // become 8. Read RR0 (known small set of bits) vs RR8 (FIFO data).
        // RR0[6]=0 always (TX Underrun unimplemented to set high). RR8 could
        // be anything. So check NOT all 0x?? matching pure FIFO; safer is the
        // reverse test below.
        $display("[%0t]   WR0=0x18 (Send Abort): read after = %02h (must be RR0, not RR8)",
                 $time, sentinel);

        // -- WR0 = 0x28 (Reset TX Int, [5:3]=101) - same bit-3-set trap. --
        bus_write(1, 1'b0, 8'h28);
        // Hard test: aim ptr at WR2=0xAB, issue 0x28, then a bare read.
        // If buggy: ptr lands at 8 -> RR8 (not 0xAB).
        // If fixed: ptr lands at 0 -> RR0 (live, not 0xAB).
        // Either way "not AB" - so use RR12 readback approach instead.
        write_ctrl(1, 4'd12, 8'h5C);   // seed
        bus_write(1, 1'b0, 8'h28);     // Reset TX Int
        bus_read (1, 1'b0, sentinel);
        // After fixed decode, ptr=0 -> RR0. After bug, ptr=8 -> RR8.
        // RR0 always has bit 6 = TX Underrun = 0 in our build, AND bit 2 = TX
        // empty = 1 (FIFO empty). So look for bit-2 set, bit-6 clear.
        if (sentinel[6] == 1'b0 && sentinel[2] == 1'b1)
            $display("[%0t]   WR0=0x28 (Reset TX Int): ptr->0 PASS (RR0=%02h)",
                     $time, sentinel);
        else begin
            $display("[%0t]   FAIL: WR0=0x28 ptr likely went to 8 (read=%02h, not RR0-shaped)",
                     $time, sentinel);
            errs = errs + 1;
        end

        // -- WR0 = 0x30 (Error Reset, [5:3]=110) - bit 3 = 0, should be fine. --
        bus_write(1, 1'b0, 8'h30);
        bus_read (1, 1'b0, sentinel);
        if (sentinel[6] == 1'b0 && sentinel[2] == 1'b1)
            $display("[%0t]   WR0=0x30 (Error Reset): ptr->0 PASS (RR0=%02h)", $time, sentinel);
        else begin
            $display("[%0t]   FAIL: WR0=0x30 read=%02h not RR0-shaped", $time, sentinel);
            errs = errs + 1;
        end

        // -- WR0 = 0x38 (Reset IUS, [5:3]=111) - bit 3 set, the bug trap. --
        bus_write(1, 1'b0, 8'h38);
        bus_read (1, 1'b0, sentinel);
        if (sentinel[6] == 1'b0 && sentinel[2] == 1'b1)
            $display("[%0t]   WR0=0x38 (Reset IUS): ptr->0 PASS (RR0=%02h)", $time, sentinel);
        else begin
            $display("[%0t]   FAIL: WR0=0x38 ptr likely went to 8 (read=%02h, not RR0-shaped)",
                     $time, sentinel);
            errs = errs + 1;
        end

        // -- WR0 = 0x0F (Point High + low bits 7) reg_ptr = 15 -> RR15 --
        bus_write(1, 1'b0, 8'h0F);
        bus_read (1, 1'b0, sentinel);
        // RR15 = wr15_a (probably 0x00 from cleanup). Hard to check uniquely.
        write_ctrl(1, 4'd15, 8'hA5);   // seed RR15 with known value
        bus_write(1, 1'b0, 8'h0F);     // Point High + 7 -> reg_ptr = 15
        bus_read (1, 1'b0, sentinel);
        if (sentinel == 8'hA5)
            $display("[%0t]   WR0=0x0F (Point High+7): ptr->15 PASS (RR15=%02h)", $time, sentinel);
        else begin
            $display("[%0t]   FAIL: WR0=0x0F read=%02h (exp A5=RR15)", $time, sentinel);
            errs = errs + 1;
        end

        // Cleanup
        write_ctrl(1, 4'd15, 8'h00);

        if (errs == 0) $display("[%0t] WR0 COMMAND TEST PASS", $time);
        else           $display("[%0t] WR0 COMMAND TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 17: Auto Enables (WR3[5])
    //   A) /CTS gates the transmitter: a queued byte is NOT sent while /CTS is
    //      deasserted (high), then drains (and loops back) once /CTS asserts.
    //   B) /DCD gates the receiver: a frame is NOT captured while /DCD is
    //      deasserted, then a later byte is received once /DCD asserts.
    //   C) Deferred /RTS deassert: clearing WR5[1] mid-transmission keeps
    //      /RTS asserted until the transmitter empties, then releases it.
    //   D) Regression: with Auto Enables OFF, /RTS follows WR5[1] immediately.
    //
    //   Channel A loopback @ 38400 baud (tx_out feeds the receiver). With
    //   Auto Enables on, TX also needs /CTS low and RX also needs /DCD low,
    //   so the modem pins are driven explicitly for each sub-test.
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 17: Auto Enables (WR3[5])", $time);

    begin : auto_en_test
        integer errs;
        integer w;
        reg [7:0] rb;
        reg       got;
        errs = 0;

        // Base config: Ch A loopback, Auto Enables ON (WR3[5]=1)
        write_ctrl(1, 4'd14, 8'h00);   // BRG off while configuring
        write_ctrl(1, 4'd4,  8'h44);   // x16, 1 stop, no parity
        write_ctrl(1, 4'd3,  8'hE1);   // RX 8 bits, RX enable, Auto Enables
        write_ctrl(1, 4'd5,  8'h6A);   // TX 8 bits, TX enable, RTS
        write_ctrl(1, 4'd12, 8'h01);   // TC = 1 -> 38400 baud
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);   // TX/RX clocks from BRG
        write_ctrl(1, 4'd14, 8'h11);   // BRG enable + loopback

        // Quiesce: with /CTS and /DCD asserted, let any leftover byte finish
        // transmitting (poll RR1[0] All Sent), give an in-flight RX frame time
        // to land, then drain the receiver. Guarantees an empty TX FIFO and an
        // idle line so no stale byte bleeds into sub-test A.
        ctsa_n = 1'b0;  dcda_n = 1'b0;
        read_ctrl(1, 4'd1, read_val);
        for (w = 0; w < 200 && !read_val[0]; w = w + 1) begin
            repeat(500) @(posedge clk);
            read_ctrl(1, 4'd1, read_val);
        end
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // ---- Sub-test A: /CTS gates the transmitter ----
        $display("[%0t] A: /CTS gates TX", $time);
        ctsa_n = 1'b1;                 // /CTS deasserted -> TX gated
        dcda_n = 1'b0;                 // /DCD asserted   -> RX enabled
        repeat(300) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // drain any stale RX
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'hC3);          // queue a byte while CTS is high
        repeat(FRAME_WAIT_CLK * 2) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        if (!read_val[0])
            $display("[%0t]   No loopback while /CTS high PASS", $time);
        else begin
            read_data(1, rb);
            $display("[%0t]   FAIL: byte sent with /CTS high (got %02h)", $time, rb);
            errs = errs + 1;
        end
        read_ctrl(1, 4'd1, read_val);  // RR1[0] = All Sent
        if (!read_val[0])
            $display("[%0t]   All-Sent low (byte still queued) PASS", $time);
        else begin
            $display("[%0t]   FAIL: All-Sent high while TX gated (RR1=%02h)", $time, read_val);
            errs = errs + 1;
        end

        // Assert /CTS, then poll for the looped-back byte (latency varies with
        // the TX frame time + the RX capture time, so read as soon as it lands
        // rather than at a single fixed instant).
        ctsa_n = 1'b0;                 // assert /CTS -> transmitter proceeds
        got = 1'b0;
        for (w = 0; w < 80 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'hC3)
            $display("[%0t]   Drained after /CTS asserted PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: /CTS drain (got=%b rb=%02h exp C3)", $time, got, rb);
            errs = errs + 1;
        end
        // Quiesce: let any in-flight frame finish, then drain.
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // ---- Sub-test B: /DCD gates the receiver ----
        $display("[%0t] B: /DCD gates RX", $time);
        // Quiesce first (CTS asserted so the transmitter can fully drain).
        ctsa_n = 1'b0;  dcda_n = 1'b0;
        read_ctrl(1, 4'd1, read_val);
        for (w = 0; w < 200 && !read_val[0]; w = w + 1) begin
            repeat(500) @(posedge clk);
            read_ctrl(1, 4'd1, read_val);
        end
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        ctsa_n = 1'b0;                 // keep TX enabled
        dcda_n = 1'b1;                 // /DCD deasserted -> RX gated
        repeat(300) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // clear any leftover from A
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h5A);          // transmits, but RX must not capture it
        repeat(FRAME_WAIT_CLK * 3) @(posedge clk);   // full frame + margin
        read_ctrl(1, 4'd0, read_val);
        if (!read_val[0])
            $display("[%0t]   No RX capture while /DCD high PASS", $time);
        else begin
            read_data(1, rb);
            $display("[%0t]   FAIL: RX captured with /DCD high (got %02h)", $time, rb);
            errs = errs + 1;
        end

        dcda_n = 1'b0;                 // assert /DCD -> receiver enabled
        repeat(300) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // make sure FIFO is clean before the test byte
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h3C);          // new byte, should be received now
        got = 1'b0;
        for (w = 0; w < 80 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'h3C)
            $display("[%0t]   RX after /DCD asserted PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: /DCD enable RX (got=%b rb=%02h exp 3C)", $time, got, rb);
            errs = errs + 1;
        end
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // ---- Sub-test C: deferred /RTS deassert ----
        $display("[%0t] C: deferred /RTS deassert", $time);
        ctsa_n = 1'b0;  dcda_n = 1'b0; // TX and RX both enabled
        write_ctrl(1, 4'd3, 8'hE1);    // ensure Auto Enables on
        write_ctrl(1, 4'd5, 8'h6A);    // RTS asserted, TX enable
        // Quiesce so the TX FIFO is empty (else a 0xAA write could be dropped).
        read_ctrl(1, 4'd1, read_val);
        for (w = 0; w < 200 && !read_val[0]; w = w + 1) begin
            repeat(500) @(posedge clk);
            read_ctrl(1, 4'd1, read_val);
        end
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // drain
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        if (rtsa_n == 1'b0)
            $display("[%0t]   /RTS asserted (WR5[1]=1) PASS", $time);
        else begin
            $display("[%0t]   FAIL: /RTS not asserted before test", $time);
            errs = errs + 1;
        end

        write_data(1, 8'hAA);          // start a transmission
        // Confirm the byte is actually accepted / in flight (All Sent low)
        // before clearing RTS, so the deferred-hold check is meaningful.
        got = 1'b0;
        for (w = 0; w < 80 && !got; w = w + 1) begin
            read_ctrl(1, 4'd1, read_val);
            if (!read_val[0]) got = 1'b1;     // RR1[0]=0 -> byte queued/transmitting
            else repeat(200) @(posedge clk);
        end
        if (!got) begin
            $display("[%0t]   FAIL: 0xAA never queued (TX FIFO?)", $time);
            errs = errs + 1;
        end
        write_ctrl(1, 4'd5, 8'h68);    // clear RTS (keep TX enable) mid-flight
        repeat(2000) @(posedge clk);   // ~100 us: still well inside the frame
        if (rtsa_n == 1'b0)
            $display("[%0t]   /RTS held during TX PASS", $time);
        else begin
            $display("[%0t]   FAIL: /RTS released while TX active", $time);
            errs = errs + 1;
        end

        // Poll for the deferred release once the transmitter empties.
        got = 1'b0;
        for (w = 0; w < 200 && !got; w = w + 1) begin
            repeat(500) @(posedge clk);
            if (rtsa_n == 1'b1) got = 1'b1;
        end
        if (got)
            $display("[%0t]   /RTS released after drain PASS", $time);
        else begin
            $display("[%0t]   FAIL: /RTS still asserted after drain", $time);
            errs = errs + 1;
        end
        read_ctrl(1, 4'd0, read_val);  // drain the looped-back 0xAA
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // ---- Sub-test D: Auto Enables OFF -> immediate /RTS deassert ----
        $display("[%0t] D: Auto Enables off -> immediate /RTS", $time);
        write_ctrl(1, 4'd3, 8'hC1);    // clear WR3[5] (Auto Enables off)
        write_ctrl(1, 4'd5, 8'h6A);    // assert RTS
        repeat(50) @(posedge clk);
        if (rtsa_n != 1'b0) begin
            $display("[%0t]   FAIL: /RTS not asserted with WR5[1]=1", $time);
            errs = errs + 1;
        end
        write_ctrl(1, 4'd5, 8'h68);    // clear RTS
        repeat(50) @(posedge clk);
        if (rtsa_n == 1'b1)
            $display("[%0t]   Immediate /RTS deassert PASS", $time);
        else begin
            $display("[%0t]   FAIL: /RTS still asserted (Auto Enables off)", $time);
            errs = errs + 1;
        end

        // Cleanup
        write_ctrl(1, 4'd5,  8'h6A);   // restore RTS/TX enable
        write_ctrl(1, 4'd14, 8'h01);   // loopback off, BRG still on
        ctsa_n = 1'b0;  dcda_n = 1'b0;
        repeat(50) @(posedge clk);

        if (errs == 0) $display("[%0t] AUTO ENABLES TEST PASS", $time);
        else           $display("[%0t] AUTO ENABLES TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 18: Auto Enables OFF -> data path is NOT gated by /CTS or /DCD
    //   The mirror of Test 17 A/B: with WR3[5]=0 the gating terms tx_cts_ok /
    //   rx_dcd_ok force to 1, so the modem inputs must have no effect on data.
    //   A) /CTS deasserted (high) -> a queued byte STILL transmits + loops back.
    //   B) /DCD deasserted (high) -> a transmitted byte IS STILL received.
    //
    //   Channel A loopback @ 38400 baud (same setup as Test 17), Auto Enables
    //   OFF (WR3[5]=0). Only the varied modem pin is moved per sub-test.
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 18: Auto Enables OFF (no /CTS or /DCD gating)", $time);

    begin : auto_en_off_test
        integer errs;
        integer w;
        reg [7:0] rb;
        reg       got;
        errs = 0;

        // Base config: Ch A loopback, Auto Enables OFF (WR3[5]=0)
        write_ctrl(1, 4'd14, 8'h00);   // BRG off while configuring
        write_ctrl(1, 4'd4,  8'h44);   // x16, 1 stop, no parity
        write_ctrl(1, 4'd3,  8'hC1);   // RX 8 bits, RX enable, Auto Enables OFF
        write_ctrl(1, 4'd5,  8'h6A);   // TX 8 bits, TX enable, RTS
        write_ctrl(1, 4'd12, 8'h01);   // TC = 1 -> 38400 baud
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);   // TX/RX clocks from BRG
        write_ctrl(1, 4'd14, 8'h11);   // BRG enable + loopback

        // Quiesce: let any leftover byte finish, then drain the receiver.
        ctsa_n = 1'b0;  dcda_n = 1'b0;
        read_ctrl(1, 4'd1, read_val);
        for (w = 0; w < 200 && !read_val[0]; w = w + 1) begin
            repeat(500) @(posedge clk);
            read_ctrl(1, 4'd1, read_val);
        end
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // ---- Sub-test A: /CTS high must NOT gate the transmitter ----
        $display("[%0t] A: /CTS high, TX must still send", $time);
        ctsa_n = 1'b1;                 // /CTS deasserted -> would gate if auto-en ON
        dcda_n = 1'b0;                 // /DCD asserted -> RX path clear either way
        repeat(300) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // drain any stale RX
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'hC3);          // queue a byte with /CTS high
        got = 1'b0;
        for (w = 0; w < 80 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'hC3)
            $display("[%0t]   Sent + looped back despite /CTS high PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: TX gated by /CTS with auto-en off (got=%b rb=%02h exp C3)", $time, got, rb);
            errs = errs + 1;
        end
        // Quiesce before sub-test B.
        repeat(FRAME_WAIT_CLK) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        // ---- Sub-test B: /DCD high must NOT gate the receiver ----
        $display("[%0t] B: /DCD high, RX must still capture", $time);
        ctsa_n = 1'b0;                 // /CTS asserted -> TX path clear either way
        dcda_n = 1'b1;                 // /DCD deasserted -> would gate if auto-en ON
        repeat(300) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // drain any leftover from A
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h5A);          // transmits, RX must still capture it
        got = 1'b0;
        for (w = 0; w < 80 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'h5A)
            $display("[%0t]   Received despite /DCD high PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: RX gated by /DCD with auto-en off (got=%b rb=%02h exp 5A)", $time, got, rb);
            errs = errs + 1;
        end

        // Cleanup
        write_ctrl(1, 4'd14, 8'h01);   // loopback off, BRG still on
        ctsa_n = 1'b0;  dcda_n = 1'b0;
        repeat(50) @(posedge clk);

        if (errs == 0) $display("[%0t] AUTO ENABLES OFF TEST PASS", $time);
        else           $display("[%0t] AUTO ENABLES OFF TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 19: /SYNC pins (async-mode status input)
    //   In async receive mode /SYNCA and /SYNCB are inputs whose level is
    //   reflected in RR0[4] (Sync/Hunt) and have NO other function (datasheet):
    //   status only -- no interrupt, no data-path effect.
    //   A) /SYNCA toggling tracks RR0[4] on Channel A.
    //   B) /SYNCB toggling tracks RR0[4] on Channel B.
    //   C) Status only: even with Sync/Hunt IE (WR15[4]) + MIE, a /SYNC edge
    //      does NOT assert /INT.
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 19: /SYNC pins -> RR0[4] (Sync/Hunt), status only", $time);

    begin : sync_pin_test
        integer errs;
        reg [7:0] rb;
        errs = 0;

        // ---- Sub-test A: /SYNCA reflected in RR0[4] (Channel A) ----
        $display("[%0t] A: /SYNCA -> RR0(A)[4]", $time);
        synca_n = 1'b1;                 // deasserted (high) -> RR0[4] = 0
        repeat(10) @(posedge clk);
        read_ctrl(1, 4'd0, rb);
        if (rb[4] == 1'b0)
            $display("[%0t]   /SYNCA high -> RR0[4]=0 PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNCA high but RR0[4]=1 (RR0=%02h)", $time, rb);
            errs = errs + 1;
        end

        synca_n = 1'b0;                 // asserted (low) -> RR0[4] = 1
        repeat(10) @(posedge clk);
        read_ctrl(1, 4'd0, rb);
        if (rb[4] == 1'b1)
            $display("[%0t]   /SYNCA low -> RR0[4]=1 PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNCA low but RR0[4]=0 (RR0=%02h)", $time, rb);
            errs = errs + 1;
        end

        synca_n = 1'b1;                 // back to deasserted -> RR0[4] = 0
        repeat(10) @(posedge clk);
        read_ctrl(1, 4'd0, rb);
        if (rb[4] == 1'b0)
            $display("[%0t]   /SYNCA released -> RR0[4]=0 PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNCA released but RR0[4]=1 (RR0=%02h)", $time, rb);
            errs = errs + 1;
        end

        // ---- Sub-test B: /SYNCB reflected in RR0[4] (Channel B) ----
        $display("[%0t] B: /SYNCB -> RR0(B)[4]", $time);
        syncb_n = 1'b1;
        repeat(10) @(posedge clk);
        read_ctrl(0, 4'd0, rb);
        if (rb[4] == 1'b0)
            $display("[%0t]   /SYNCB high -> RR0[4]=0 PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNCB high but RR0[4]=1 (RR0=%02h)", $time, rb);
            errs = errs + 1;
        end

        syncb_n = 1'b0;
        repeat(10) @(posedge clk);
        read_ctrl(0, 4'd0, rb);
        if (rb[4] == 1'b1)
            $display("[%0t]   /SYNCB low -> RR0[4]=1 PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNCB low but RR0[4]=0 (RR0=%02h)", $time, rb);
            errs = errs + 1;
        end

        syncb_n = 1'b1;
        repeat(10) @(posedge clk);
        read_ctrl(0, 4'd0, rb);
        if (rb[4] == 1'b0)
            $display("[%0t]   /SYNCB released -> RR0[4]=0 PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNCB released but RR0[4]=1 (RR0=%02h)", $time, rb);
            errs = errs + 1;
        end

        // ---- Sub-test C: status only -> no interrupt on /SYNC edge ----
        $display("[%0t] C: /SYNC edge raises no interrupt", $time);
        write_ctrl(1, 4'd1,  8'h00);   // Ch A: RX/TX interrupts off
        write_ctrl(1, 4'd15, 8'h10);   // Sync/Hunt IE (WR15[4])
        write_ctrl(1, 4'd9,  8'h08);   // MIE on (WR9[3])
        write_ctrl(1, 4'd0,  8'h10);   // Reset Ext/Status latches
        repeat(10) @(posedge clk);
        synca_n = 1'b0;                 // edge low
        repeat(20) @(posedge clk);
        synca_n = 1'b1;                 // edge high
        repeat(20) @(posedge clk);
        if (int_n == 1'b1)
            $display("[%0t]   No /INT from /SYNC edge PASS", $time);
        else begin
            $display("[%0t]   FAIL: /SYNC edge asserted /INT (int_n=%b)", $time, int_n);
            errs = errs + 1;
        end

        // Cleanup: disable MIE / Sync IE again
        write_ctrl(1, 4'd9,  8'h00);
        write_ctrl(1, 4'd15, 8'h00);
        synca_n = 1'b1;  syncb_n = 1'b1;

        if (errs == 0) $display("[%0t] SYNC PIN TEST PASS", $time);
        else           $display("[%0t] SYNC PIN TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 20: x32 / x64 clock-mode loopback (Channel A)
    //   Exercises the WR4[7:6] clock-mode decode beyond x16 -- proves the
    //   widened sample counters reach 31 (x32) and 63 (x64) and a byte still
    //   round-trips. Self-clocked loopback is baud-agnostic, so only the
    //   internal sample-count path is under test here (waits are poll-based
    //   because x64 is 4x slower than x16 and exceeds FRAME_WAIT_CLK).
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 20: x32 / x64 clock-mode loopback (Ch A)", $time);

    begin : clkmode_test
        integer errs;
        integer w;
        reg [7:0] rb;
        reg       got;
        errs = 0;

        // ---- Sub-test A: x32 (WR4[7:6]=10) ----
        $display("[%0t] A: x32 loopback", $time);
        write_ctrl(1, 4'd14, 8'h00);   // BRG off while configuring
        write_ctrl(1, 4'd4,  8'h84);   // x32, 1 stop, no parity
        write_ctrl(1, 4'd3,  8'hC1);   // RX 8 bits, RX enable
        write_ctrl(1, 4'd5,  8'h6A);   // TX 8 bits, TX enable, RTS
        write_ctrl(1, 4'd12, 8'h01);   // TC = 1
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);   // TX/RX clocks from BRG
        write_ctrl(1, 4'd14, 8'h11);   // BRG enable + loopback
        repeat(100) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // drain any stale RX
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h93);
        got = 1'b0;
        for (w = 0; w < 200 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'h93)
            $display("[%0t]   x32 loopback PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: x32 loopback (got=%b rb=%02h exp 93)", $time, got, rb);
            errs = errs + 1;
        end

        // ---- Sub-test B: x64 (WR4[7:6]=11) ----
        $display("[%0t] B: x64 loopback", $time);
        write_ctrl(1, 4'd14, 8'h00);   // BRG off while reconfiguring clock mode
        write_ctrl(1, 4'd4,  8'hC4);   // x64, 1 stop, no parity
        write_ctrl(1, 4'd14, 8'h11);   // BRG enable + loopback
        repeat(100) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h6C);
        got = 1'b0;
        for (w = 0; w < 200 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'h6C)
            $display("[%0t]   x64 loopback PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: x64 loopback (got=%b rb=%02h exp 6C)", $time, got, rb);
            errs = errs + 1;
        end

        // Cleanup: restore x16
        write_ctrl(1, 4'd14, 8'h00);
        write_ctrl(1, 4'd4,  8'h44);   // back to x16
        write_ctrl(1, 4'd14, 8'h01);   // loopback off, BRG on
        repeat(50) @(posedge clk);

        if (errs == 0) $display("[%0t] CLOCK-MODE TEST PASS", $time);
        else           $display("[%0t] CLOCK-MODE TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 21: RTxC-from-XTAL full-rate override loopback (Channel A)
    //   WR11[7]=1 (RTxC=XTAL) with RX src (WR11[6:5]=00) and TX src
    //   (WR11[4:3]=00) = RTxC triggers the per-channel RTXC_XTAL_FULLRATE_A
    //   override: the serial engine is clocked every sclk cycle (RTxC == sclk)
    //   instead of from the tied-off pin. A byte must still round-trip via
    //   loopback. The WR4 x16 divide still applies, so bit = 16 sclk cycles.
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 21: RTxC-XTAL full-rate override loopback (Ch A)", $time);

    begin : rtxc_fullrate_test
        integer errs;
        integer w;
        reg [7:0] rb;
        reg       got;
        errs = 0;

        write_ctrl(1, 4'd14, 8'h00);   // BRG off while configuring
        write_ctrl(1, 4'd4,  8'h44);   // x16, 1 stop, no parity
        write_ctrl(1, 4'd3,  8'hC1);   // RX 8 bits, RX enable
        write_ctrl(1, 4'd5,  8'h6A);   // TX 8 bits, TX enable, RTS
        write_ctrl(1, 4'd12, 8'h01);   // TC = 1 (unused under the override)
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h80);   // WR11[7]=1 XTAL; RX/TX src = RTxC (00/00)
        write_ctrl(1, 4'd14, 8'h11);   // loopback on (BRG bit set but irrelevant here)
        repeat(100) @(posedge clk);
        read_ctrl(1, 4'd0, read_val);  // drain any stale RX
        while (read_val[0]) begin read_data(1, read_val); read_ctrl(1, 4'd0, read_val); end

        write_data(1, 8'h3C);
        got = 1'b0;
        for (w = 0; w < 200 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'h3C)
            $display("[%0t]   Full-rate loopback PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: full-rate loopback (got=%b rb=%02h exp 3C)", $time, got, rb);
            errs = errs + 1;
        end

        // Cleanup: restore BRG-sourced clocks
        write_ctrl(1, 4'd11, 8'h50);   // TX/RX clocks from BRG
        write_ctrl(1, 4'd14, 8'h01);   // loopback off, BRG on
        repeat(50) @(posedge clk);

        if (errs == 0) $display("[%0t] RTXC FULL-RATE TEST PASS", $time);
        else           $display("[%0t] RTXC FULL-RATE TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    // Test 22: hardware reset via simultaneous /RD + /WR (RDWR_RESET_EN)
    //   The real Z8530 has no reset pin; driving /RD and /WR low together
    //   while selected is the datasheet hardware reset (= WR9 0xC0). Checks:
    //   A) Registers programmed on both channels read back cleared afterwards
    //      (RR12/RR13 -> 0), /INT deasserted, RR0 back to idle shape.
    //   B) The device still works after the reset: reconfigure Channel A and
    //      loop back one byte (proves FIFOs/CDC came out of reset cleanly).
    //------------------------------------------------------------------------
    $display("\n[%0t] Test 22: /RD+/WR simultaneous hardware reset", $time);

    begin : rdwr_reset_test
        integer errs;
        integer w;
        reg [7:0] rb;
        reg       got;
        errs = 0;

        // Program recognizable state on both channels + MIE
        write_ctrl(1, 4'd12, 8'h5A);
        write_ctrl(1, 4'd13, 8'h3C);
        write_ctrl(0, 4'd12, 8'h77);
        write_ctrl(1, 4'd9,  8'h08);   // MIE
        read_ctrl(1, 4'd12, rb);
        if (rb !== 8'h5A) begin
            $display("[%0t]   FAIL: precondition, RR12(A)=%02h exp 5A", $time, rb);
            errs = errs + 1;
        end

        // ---- The illegal combination: /RD + /WR both low through a normal
        //      2-5-2 bus cycle (pointer is at 0, data 0x00 -> null WR0 cmd,
        //      wiped by the reset window anyway) ----
        @(posedge clk);
        a_b     <= 1'b1;
        d_c     <= 1'b0;
        data_in <= 8'h00;
        wr_n    <= 1'b0;
        rd_n    <= 1'b0;               // both strobes low
        cs_n    <= 1'b1;
        repeat(2) @(posedge clk);
        cs_n    <= 1'b0;               // selected: reset condition detected
        repeat(5) @(posedge clk);
        cs_n    <= 1'b1;
        repeat(2) @(posedge clk);
        wr_n    <= 1'b1;
        rd_n    <= 1'b1;
        @(posedge clk);
        $display("[%0t]   /RD+/WR cycle issued", $time);

        // Reset window is RST_STRETCH (96 clk ~ 4.8 us) + sclk CDC tail; writes
        // during it are ignored, so wait well past it before touching the chip.
        repeat(2500) @(posedge clk);

        // ---- Sub-test A: state cleared ----
        read_ctrl(1, 4'd12, rb);
        if (rb === 8'h00)
            $display("[%0t]   RR12(A) cleared PASS", $time);
        else begin
            $display("[%0t]   FAIL: RR12(A)=%02h exp 00", $time, rb);
            errs = errs + 1;
        end
        read_ctrl(1, 4'd13, rb);
        if (rb === 8'h00)
            $display("[%0t]   RR13(A) cleared PASS", $time);
        else begin
            $display("[%0t]   FAIL: RR13(A)=%02h exp 00", $time, rb);
            errs = errs + 1;
        end
        read_ctrl(0, 4'd12, rb);
        if (rb === 8'h00)
            $display("[%0t]   RR12(B) cleared PASS", $time);
        else begin
            $display("[%0t]   FAIL: RR12(B)=%02h exp 00", $time, rb);
            errs = errs + 1;
        end
        if (int_n == 1'b1)
            $display("[%0t]   /INT deasserted PASS", $time);
        else begin
            $display("[%0t]   FAIL: /INT asserted after reset", $time);
            errs = errs + 1;
        end
        read_ctrl(1, 4'd0, rb);
        if (rb[2] == 1'b1 && rb[0] == 1'b0)
            $display("[%0t]   RR0 idle shape PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: RR0=%02h (exp bit2=1, bit0=0)", $time, rb);
            errs = errs + 1;
        end

        // ---- Sub-test B: functional after reset (Ch A loopback) ----
        $display("[%0t] B: post-reset loopback", $time);
        write_ctrl(1, 4'd4,  8'h44);   // x16, 1 stop, no parity
        write_ctrl(1, 4'd3,  8'hC1);   // RX 8 bits, RX enable
        write_ctrl(1, 4'd5,  8'h6A);   // TX 8 bits, TX enable, RTS
        write_ctrl(1, 4'd12, 8'h01);   // TC = 1
        write_ctrl(1, 4'd13, 8'h00);
        write_ctrl(1, 4'd11, 8'h50);   // TX/RX clocks from BRG
        write_ctrl(1, 4'd14, 8'h11);   // BRG enable + loopback
        repeat(100) @(posedge clk);

        write_data(1, 8'hA7);
        got = 1'b0;
        for (w = 0; w < 80 && !got; w = w + 1) begin
            repeat(1000) @(posedge clk);
            read_ctrl(1, 4'd0, read_val);
            if (read_val[0]) begin read_data(1, rb); got = 1'b1; end
        end
        if (got && rb == 8'hA7)
            $display("[%0t]   Post-reset loopback PASS (%02h)", $time, rb);
        else begin
            $display("[%0t]   FAIL: post-reset loopback (got=%b rb=%02h exp A7)", $time, got, rb);
            errs = errs + 1;
        end

        // Cleanup
        write_ctrl(1, 4'd14, 8'h01);   // loopback off, BRG on
        repeat(50) @(posedge clk);

        if (errs == 0) $display("[%0t] RDWR RESET TEST PASS", $time);
        else           $display("[%0t] RDWR RESET TEST FAIL: %0d errors", $time, errs);
    end

    //------------------------------------------------------------------------
    $display("\n===========================================");
    $display("Z8530 SCC Testbench Complete");
    $display("===========================================");
    #1000;
    $finish;
end

//============================================================================
// Optional TX-line sniffer (sample txda using the Channel A bit time, ignores
// activity before reset_n).
//============================================================================
reg [7:0] captured_byte;
integer   bit_count;
reg       capturing;
initial begin capturing = 0; captured_byte = 0; bit_count = 0; end

always @(negedge txda) begin
    if (!capturing && reset_n) begin
        capturing     = 1;
        bit_count     = 0;
        captured_byte = 0;
        #(BIT_TIME_A_NS + BIT_TIME_A_NS/2);   // skip start, half-bit into data 0
        repeat(8) begin
            captured_byte = {txda, captured_byte[7:1]};
            #(BIT_TIME_A_NS);
        end
        $display("[%0t] Channel A TX line: 0x%02h", $time, captured_byte);
        capturing = 0;
    end
end

// ---- Timeout watchdog ----
initial begin
    #500000000;   // 500 ms
    $display("ERROR: Simulation timeout!");
    $finish;
end

endmodule
