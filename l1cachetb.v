`timescale 1ns/1ps
module tb_vipt_l1_cache;
    parameter ADDR_WIDTH = 32;
    parameter DATA_WIDTH = 32;
    parameter OFFSET_BITS = 4;
    parameter INDEX_BITS = 4; // small for test
    parameter BYTES_PER_WORD = DATA_WIDTH/8;
    parameter BLOCK_BYTES = (1 << OFFSET_BITS);
    parameter WORDS_PER_BLOCK = BLOCK_BYTES / BYTES_PER_WORD;

    reg clk;
    reg reset_n;

    // CPU side signals
    reg cpu_req;
    reg cpu_write;
    reg [ADDR_WIDTH-1:0] cpu_virt_addr;
    reg [ADDR_WIDTH-1:0] cpu_phys_addr;
    reg [DATA_WIDTH-1:0] cpu_wdata;
    wire cpu_ready;
    wire [DATA_WIDTH-1:0] cpu_rdata;
    wire cpu_miss;

    // Mem side
    wire mem_req;
    wire mem_write;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [DATA_WIDTH-1:0] mem_wdata;
    reg mem_ready;
    reg mem_resp_valid;
    reg [DATA_WIDTH-1:0] mem_rdata;

    // Instantiate DUT
    vipt_l1_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .OFFSET_BITS(OFFSET_BITS),
        .INDEX_BITS(INDEX_BITS)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .cpu_req(cpu_req),
        .cpu_write(cpu_write),
        .cpu_virt_addr(cpu_virt_addr),
        .cpu_phys_addr(cpu_phys_addr),
        .cpu_wdata(cpu_wdata),
        .cpu_ready(cpu_ready),
        .cpu_rdata(cpu_rdata),
        .cpu_miss(cpu_miss),

        .mem_req(mem_req),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_ready(mem_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_rdata(mem_rdata)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk; // 100 MHz

    // Simple behavioral memory model:
    // - Accepts mem_req when asserted (mem_ready = 1 for one cycle)
    // - For read requests, returns WORDS_PER_BLOCK words sequentially by asserting mem_resp_valid one word per cycle
    // - For write requests, accepts (no further action)
    integer i;
    reg [31:0] mem_cycles_until_resp;
    reg mem_busy;
    reg [ADDR_WIDTH-1:0] last_req_addr;
    integer resp_word_idx;

    initial begin
        reset_n = 0;
        cpu_req = 0;
        cpu_write = 0;
        cpu_virt_addr = 0;
        cpu_phys_addr = 0;
        cpu_wdata = 0;
        mem_ready = 0;
        mem_resp_valid = 0;
        mem_rdata = 0;
        mem_busy = 0;
        mem_cycles_until_resp = 0;
        last_req_addr = 0;
        resp_word_idx = 0;

        #20;
        reset_n = 1;
        #20;

        $display("[%0t] Starting tests", $time);

        // Test sequence:
        // 1) Load A (miss -> refill)
        // 2) Load A again (hit)
        // 3) Store B (miss -> refill + write)
        // 4) Store B again (hit)
        // 5) Thrash set to force eviction and writeback

        task issue_req;
            input is_write;
            input [ADDR_WIDTH-1:0] vaddr;
            input [ADDR_WIDTH-1:0] paddr;
            input [DATA_WIDTH-1:0] wdat;
            begin
                @(posedge clk);
                cpu_write <= is_write;
                cpu_virt_addr <= vaddr;
                cpu_phys_addr <= paddr;
                cpu_wdata <= wdat;
                cpu_req <= 1;
                // hold until accepted (cpu_ready asserted)
                wait (cpu_ready == 1);
                @(posedge clk);
                cpu_req <= 0;
                // wait until operation finishes (cpu_ready goes high again)
                wait (cpu_ready == 1);
                @(posedge clk);
            end
        endtask

        // Read A
        $display("[%0t] read A (miss -> refill)", $time);
        issue_req(0, 32'h0000_1004, 32'h0000_1004, 32'h0);

        // read A again (hit)
        $display("[%0t] read A again (should be hit)", $time);
        issue_req(0, 32'h0000_1004, 32'h0000_1004, 32'h0);

        // write B
        $display("[%0t] write B (miss -> refill then write)", $time);
        issue_req(1, 32'h0000_2008, 32'h0000_2008, 32'hDEAD_BEEF);

        // write B again (hit)
        $display("[%0t] write B again (hit)", $time);
        issue_req(1, 32'h0000_2008, 32'h0000_2008, 32'hFEED_FACE);

        // Thrash a chosen index to cause evictions
        integer t;
        reg [ADDR_WIDTH-1:0] v;
        reg [ADDR_WIDTH-1:0] p;
        reg [ADDR_WIDTH-1:0] base;
        base = (4 << OFFSET_BITS); // set index = 4
        for (t = 0; t < 6; t = t + 1) begin
            v = (t << (OFFSET_BITS + INDEX_BITS)) | base | 4;
            p = v;
            $display("[%0t] thrash read tag=%0d addr=%08h", $time, t, v);
            issue_req(0, v, p, 0);
        end

        #200;
        $display("TESTBENCH: finished");
        $finish;
    end

    // Memory handshake behavior (simple)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mem_ready <= 0;
            mem_resp_valid <= 0;
            mem_busy <= 0;
            mem_cycles_until_resp <= 0;
            resp_word_idx <= 0;
        end else begin
            // Accept incoming mem_req if not busy
            if (mem_req && !mem_busy) begin
                mem_ready <= 1;
                mem_busy <= 1;
                last_req_addr <= mem_addr;
                // If read: schedule responses after a small latency
                if (!mem_write) begin
                    mem_cycles_until_resp <= 3; // 3 cycle latency before first word
                    resp_word_idx <= 0;
                end else begin
                    // writeback: accept and clear busy next cycle
                    mem_cycles_until_resp <= 0;
                end
            end else begin
                mem_ready <= 0;
            end

            // For writes: clear busy on next cycle
            if (mem_busy && mem_write && !mem_req) begin
                mem_busy <= 0;
            end

            // For reads: count down latency, then produce WORDS_PER_BLOCK words one per cycle
            if (mem_busy && !mem_write && mem_cycles_until_resp > 0) begin
                mem_cycles_until_resp <= mem_cycles_until_resp - 1;
                mem_resp_valid <= 0;
            end else if (mem_busy && !mem_write && mem_cycles_until_resp == 0) begin
                // produce one word per cycle
                mem_resp_valid <= 1;
                // simple pattern: data = mem_addr + byte_offset (word_index * 4)
                mem_rdata <= last_req_addr + (resp_word_idx * BYTES_PER_WORD);
                resp_word_idx <= resp_word_idx + 1;
                if (resp_word_idx >= (WORDS_PER_BLOCK - 1)) begin
                    // after last word, clear busy next cycle
                    mem_busy <= 0;
                end
            end else begin
                mem_resp_valid <= 0;
            end
        end
    end

endmodule
