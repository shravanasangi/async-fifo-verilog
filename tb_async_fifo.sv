`timescale 1ns/1ps

// ============================================================================
// Self-checking testbench for async_fifo
//
//  Test plan (run in order):
//    1. Write-heavy random traffic      (FIFO mostly full)
//    2. Read-heavy random traffic       (FIFO mostly empty)
//    3. Balanced random traffic
//    4. Both sides saturated (100% enables on both clocks)
//    5. Directed: drain to empty, fill to full, writes-when-full,
//       reads-when-empty, occupancy checks
//    6. Reset in the middle of traffic, reset while full, short reset pulse,
//       with traffic resumed and re-checked after every reset
//    7. Final drain, then summary
//
//  Scoreboard: every accepted write is pushed into a queue, every accepted
//  read pops it and compares against rd_data.
//
//  Change WR_HALF / RD_HALF to test other clock ratios, ADDR_WIDTH for other
//  depths (>= 2), VERBOSE = 0 for a quieter log.
// ============================================================================
module tb_async_fifo;

    parameter DATA_WIDTH = 8;
    parameter ADDR_WIDTH = 3;
    parameter WR_HALF    = 5;      // write clock period = 10 ns
    parameter RD_HALF    = 7;      // read  clock period = 14 ns
    parameter VERBOSE    = 1;      // 1 = print every accepted/rejected access

    localparam DEPTH = 1 << ADDR_WIDTH;

    // ------------------------------------------------------------------
    // DUT signals
    // ------------------------------------------------------------------
    reg                   wr_clk = 1'b0;
    reg                   rd_clk = 1'b0;
    reg                   rst    = 1'b1;
    reg                   wr_en  = 1'b0;
    reg                   rd_en  = 1'b0;
    reg  [DATA_WIDTH-1:0] wr_data = 0;

    wire [DATA_WIDTH-1:0] rd_data;
    wire                  full, empty;

    // ------------------------------------------------------------------
    // Scoreboard and counters
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] expected_q [$];

    integer write_count     = 0;   // accepted writes
    integer read_count      = 0;   // accepted reads
    integer flushed_count   = 0;   // entries thrown away by resets
    integer rejected_writes = 0;
    integer rejected_reads  = 0;
    integer error_count     = 0;
    integer reset_count     = 0;

    // Stimulus knobs
    integer wr_prob  = 0;          // % chance of wr_en each write clock
    integer rd_prob  = 0;          // % chance of rd_en each read clock
    reg     wr_drive = 1'b0;
    reg     rd_drive = 1'b0;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) dut (
        .wr_clk  (wr_clk),
        .rd_clk  (rd_clk),
        .rst     (rst),
        .wr_en   (wr_en),
        .rd_en   (rd_en),
        .wr_data (wr_data),
        .rd_data (rd_data),
        .full    (full),
        .empty   (empty)
    );

    // ------------------------------------------------------------------
    // Clocks
    // ------------------------------------------------------------------
    initial forever #(WR_HALF) wr_clk = ~wr_clk;
    initial forever #(RD_HALF) rd_clk = ~rd_clk;

    // ------------------------------------------------------------------
    // Stimulus drivers (change on the falling edge, DUT samples on rising)
    // ------------------------------------------------------------------
    always @(negedge wr_clk) begin
        if (wr_drive) begin
            wr_en   = ($urandom_range(0, 99) < wr_prob);
            wr_data = $urandom_range(0, (1 << DATA_WIDTH) - 1);
        end
        else begin
            wr_en = 1'b0;
        end
    end

    always @(negedge rd_clk) begin
        if (rd_drive)
            rd_en = ($urandom_range(0, 99) < rd_prob);
        else
            rd_en = 1'b0;
    end

    // ==================================================================
    // WRITE MONITOR
    // ==================================================================
    always @(posedge wr_clk) begin
        if (!rst) begin
            if (wr_en && !full) begin
                expected_q.push_back(wr_data);
                write_count = write_count + 1;

                if (expected_q.size() > DEPTH) begin
                    $display("[%0t] ERROR: occupancy %0d exceeds DEPTH %0d (overflow)",
                             $time, expected_q.size(), DEPTH);
                    error_count = error_count + 1;
                end

                if (VERBOSE)
                    $display("[%0t] WRITE accepted: %0h", $time, wr_data);
            end
            else if (wr_en && full) begin
                rejected_writes = rejected_writes + 1;
                if (VERBOSE)
                    $display("[%0t] WRITE rejected: FULL", $time);
            end
        end
    end

    // ==================================================================
    // READ MONITOR + CHECKER
    // ==================================================================
    always @(posedge rd_clk) begin : rd_mon
        reg [DATA_WIDTH-1:0] exp_data;

        if (!rst) begin
            if (rd_en && empty) begin
                rejected_reads = rejected_reads + 1;
            end
            else if (rd_en && !empty) begin
                if (expected_q.size() == 0) begin
                    $display("[%0t] ERROR: read accepted but scoreboard is empty (underflow)",
                             $time);
                    error_count = error_count + 1;
                end
                else begin
                    exp_data = expected_q.pop_front();

                    #0.1;   // rd_data is registered, wait for it to update

                    if (rd_data !== exp_data) begin
                        $display("[%0t] ERROR: expected=%0h got=%0h",
                                 $time, exp_data, rd_data);
                        error_count = error_count + 1;
                    end
                    else if (VERBOSE) begin
                        $display("[%0t] READ PASS: %0h", $time, rd_data);
                    end

                    read_count = read_count + 1;
                end
            end
        end
    end

    // ==================================================================
    // HELPER TASKS
    // ==================================================================

    // Run random traffic with the given enable probabilities for N write clocks
    task run_phase(input integer wr_p, input integer rd_p, input integer cycles);
        begin
            wr_prob  = wr_p;
            rd_prob  = rd_p;
            wr_drive = 1'b1;
            rd_drive = 1'b1;
            repeat (cycles) @(posedge wr_clk);
        end
    endtask

    // Check flags and scoreboard occupancy at a quiet point
    task check_state(input integer exp_empty,
                     input integer exp_full,
                     input integer exp_occupancy,
                     input string tag);
        begin
            @(negedge wr_clk);
            if (empty !== exp_empty[0]) begin
                $display("[%0t] ERROR (%0s): empty=%b expected %0d",
                         $time, tag, empty, exp_empty);
                error_count = error_count + 1;
            end
            if (full !== exp_full[0]) begin
                $display("[%0t] ERROR (%0s): full=%b expected %0d",
                         $time, tag, full, exp_full);
                error_count = error_count + 1;
            end
            if (expected_q.size() != exp_occupancy) begin
                $display("[%0t] ERROR (%0s): occupancy=%0d expected %0d",
                         $time, tag, expected_q.size(), exp_occupancy);
                error_count = error_count + 1;
            end
            $display("[%0t] CHECK  (%0s): empty=%b full=%b occupancy=%0d",
                     $time, tag, empty, full, expected_q.size());
        end
    endtask

    // Reset in the middle of operation.
    //   hold_cycles : write clocks the reset is held while traffic is still
    //                 being driven into the DUT (it must ignore it)
    // After release the stimulus is stopped for a few clocks, then flags and
    // rd_data are checked. The scoreboard is flushed at the moment of reset.
    task apply_reset(input integer hold_cycles);
        begin
            @(negedge wr_clk);
            flushed_count = flushed_count + expected_q.size();
            $display("[%0t] RESET asserted, flushing %0d entries",
                     $time, expected_q.size());
            expected_q.delete();
            rst = 1'b1;
            reset_count = reset_count + 1;

            repeat (hold_cycles) @(negedge wr_clk);

            wr_drive = 1'b0;
            rd_drive = 1'b0;
            repeat (2) @(negedge wr_clk);

            rst = 1'b0;

            // wait for both domains to leave reset (2 edges each) plus margin
            repeat (4) @(negedge wr_clk);
            repeat (4) @(negedge rd_clk);

            if (empty !== 1'b1 || full !== 1'b0 || rd_data !== {DATA_WIDTH{1'b0}}) begin
                $display("[%0t] ERROR: bad state after reset: empty=%b full=%b rd_data=%0h",
                         $time, empty, full, rd_data);
                error_count = error_count + 1;
            end
            else begin
                $display("[%0t] CHECK  (after reset): empty=1 full=0 rd_data=0", $time);
            end
        end
    endtask

    // ==================================================================
    // MAIN TEST SEQUENCE
    // ==================================================================
    integer before_cnt;

    initial begin
        // initial reset (traffic off)
        repeat (5) @(posedge wr_clk);
        @(negedge wr_clk);
        rst = 1'b0;
        repeat (4) @(negedge wr_clk);
        repeat (4) @(negedge rd_clk);

        // ---- 1. write-heavy ----------------------------------------
        $display("\n--- PHASE 1: write-heavy random ---");
        run_phase(80, 30, 500);

        // ---- 2. read-heavy -----------------------------------------
        $display("\n--- PHASE 2: read-heavy random ---");
        run_phase(30, 80, 500);

        // ---- 3. balanced -------------------------------------------
        $display("\n--- PHASE 3: balanced random ---");
        run_phase(60, 60, 500);

        // ---- 4. both saturated -------------------------------------
        $display("\n--- PHASE 4: both sides saturated ---");
        run_phase(100, 100, 300);

        // ---- 5. directed corner cases ------------------------------
        $display("\n--- PHASE 5: directed drain / fill ---");

        // drain to empty
        run_phase(0, 100, 60);
        check_state(1, 0, 0, "drained");

        // reads while empty must be rejected
        before_cnt = rejected_reads;
        repeat (10) @(posedge rd_clk);
        if (rejected_reads <= before_cnt) begin
            $display("[%0t] ERROR: reads while empty were not rejected", $time);
            error_count = error_count + 1;
        end
        check_state(1, 0, 0, "empty, reads rejected");

        // fill to full
        run_phase(100, 0, 60);
        check_state(0, 1, DEPTH, "filled");

        // writes while full must be rejected and must not change occupancy
        before_cnt = rejected_writes;
        repeat (10) @(posedge wr_clk);
        if (rejected_writes <= before_cnt) begin
            $display("[%0t] ERROR: writes while full were not rejected", $time);
            error_count = error_count + 1;
        end
        check_state(0, 1, DEPTH, "full, writes rejected");

        // ---- 6. resets ---------------------------------------------
        $display("\n--- PHASE 6: resets ---");

        // 6a. reset while FIFO is full, traffic still toggling into DUT
        apply_reset(5);
        run_phase(60, 60, 300);

        // 6b. reset in the middle of random traffic
        apply_reset(5);
        run_phase(70, 50, 300);

        // 6c. very short reset pulse during traffic
        apply_reset(1);
        run_phase(60, 60, 300);

        // ---- 7. final drain ----------------------------------------
        $display("\n--- PHASE 7: final drain ---");
        run_phase(0, 100, 80);
        wr_drive = 1'b0;
        rd_drive = 1'b0;
        repeat (4) @(posedge rd_clk);
        check_state(1, 0, 0, "final drain");

        // ---- summary -----------------------------------------------
        $display("\n====================================");
        $display(" ASYNC FIFO VERIFICATION SUMMARY");
        $display("====================================");
        $display("Accepted writes  : %0d", write_count);
        $display("Accepted reads   : %0d", read_count);
        $display("Flushed by reset : %0d", flushed_count);
        $display("Resets applied   : %0d", reset_count);
        $display("Rejected writes  : %0d  (full hit)",  rejected_writes);
        $display("Rejected reads   : %0d  (empty hit)", rejected_reads);
        $display("Remaining entries: %0d", expected_q.size());
        $display("Errors           : %0d", error_count);

        if (error_count == 0 &&
            expected_q.size() == 0 &&
            write_count == read_count + flushed_count &&
            rejected_writes > 0 &&
            rejected_reads  > 0)
            $display("\n*** ALL TESTS PASSED ***");
        else
            $display("\n*** TEST FAILED ***");

        $finish;
    end

    // ------------------------------------------------------------------
    // Watchdog: fail instead of hanging if something stalls
    // ------------------------------------------------------------------
    initial begin
        #2000000;
        $display("*** TEST FAILED: watchdog timeout ***");
        $finish;
    end

    // ------------------------------------------------------------------
    // Waveform
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("async_fifo_random.vcd");
        $dumpvars(0, tb_async_fifo);
    end

endmodule
