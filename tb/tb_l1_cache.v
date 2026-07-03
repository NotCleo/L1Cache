// =============================================================================
//  tb_l1_cache.v — Directed testbench for l1_cache.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_l1_cache;
    localparam ADDR_W = 32;
    localparam DATA_W = 32;
    localparam LINE_B = 64;
    localparam SETS   = 64;
    localparam WAYS   = 4;
    localparam BUS_BEAT_W = 32;
    localparam BUS_BYTE_W = BUS_BEAT_W/8;
    localparam BEATS_PER_LINE = (LINE_B*8)/BUS_BEAT_W;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;

    reg                cpu_req;
    reg                cpu_we;
    reg [ADDR_W-1:0]   cpu_vaddr;
    reg [ADDR_W-1:0]   cpu_paddr;
    reg [DATA_W-1:0]   cpu_wdata;
    reg [DATA_W/8-1:0] cpu_be;
    wire               cpu_ready;
    wire [DATA_W-1:0]  cpu_rdata;
    wire               cpu_rvalid;

    wire               mem_req;
    wire               mem_we;
    wire [ADDR_W-1:0]  mem_addr;
    wire [BUS_BEAT_W-1:0] mem_wdata;
    reg                mem_gnt;
    reg                mem_rvalid;
    reg  [BUS_BEAT_W-1:0] mem_rdata;

    l1_cache #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .LINE_B(LINE_B),
        .SETS(SETS), .WAYS(WAYS), .PAGE_B(4096),
        .REPL(0), .CWF(1), .BUS_BEAT_W(BUS_BEAT_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_req(cpu_req), .cpu_we(cpu_we),
        .cpu_vaddr(cpu_vaddr), .cpu_paddr(cpu_paddr),
        .cpu_wdata(cpu_wdata), .cpu_be(cpu_be),
        .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata), .cpu_rvalid(cpu_rvalid),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_gnt(mem_gnt), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata)
    );

    // ---- 1 MB backing store ----
    reg [7:0] backing [0:'h001FFFFF];
    integer init_i;
    initial begin
        for (init_i = 0; init_i < 'h00200000; init_i = init_i + 1) begin
            backing[init_i] = init_i[7:0] ^ init_i[15:8];
        end
    end

    // ---- memory transactor ----
    initial begin
        mem_gnt    = 0;
        mem_rvalid = 0;
        mem_rdata  = 0;
    end

    always @(posedge clk) begin
        mem_gnt    <= 1'b0;
        mem_rvalid <= 1'b0;
        if (mem_req) begin
            mem_gnt <= 1'b1;
            if (mem_we) begin
                backing[mem_addr  ] <= mem_wdata[ 7: 0];
                backing[mem_addr+1] <= mem_wdata[15: 8];
                backing[mem_addr+2] <= mem_wdata[23:16];
                backing[mem_addr+3] <= mem_wdata[31:24];
            end else begin
                mem_rdata <= { backing[mem_addr+3], backing[mem_addr+2],
                               backing[mem_addr+1], backing[mem_addr  ] };
                mem_rvalid <= 1'b1;
            end
        end
    end

    // ---- helpers ----
    integer errors;
    initial errors = 0;

    task do_read;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] expected;
        begin
            wait (cpu_ready);
            @(posedge clk);
            cpu_req   <= 1;
            cpu_we    <= 0;
            cpu_vaddr <= addr;
            cpu_paddr <= addr;
            cpu_be    <= 4'hF;
            @(posedge clk);
            cpu_req   <= 0;
            wait (cpu_rvalid);
            if (cpu_rdata !== expected) begin
                $display("FAIL: read @%h got %h expected %h", addr, cpu_rdata, expected);
                errors = errors + 1;
            end else begin
                $display("PASS: read @%h got %h", addr, cpu_rdata);
            end
            @(posedge clk);
        end
    endtask

    task do_write;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] data;
        input [3:0] be;
        begin
            wait (cpu_ready);
            @(posedge clk);
            cpu_req   <= 1;
            cpu_we    <= 1;
            cpu_vaddr <= addr;
            cpu_paddr <= addr;
            cpu_wdata <= data;
            cpu_be    <= be;
            @(posedge clk);
            cpu_req   <= 0;
            @(posedge clk);
            wait (cpu_ready);
            $display("DONE: write @%h data=%h be=%b", addr, data, be);
        end
    endtask

    function [31:0] backing_word;
        input [ADDR_W-1:0] addr;
        begin
            backing_word = { backing[addr+3], backing[addr+2],
                             backing[addr+1], backing[addr  ] };
        end
    endfunction

    reg [31:0] tmpw, expw;

    initial begin
        $dumpfile("tb_l1_cache.vcd");
        $dumpvars(0, tb_l1_cache);

        cpu_req   = 0; cpu_we = 0; cpu_be = 0;
        cpu_vaddr = 0; cpu_paddr = 0; cpu_wdata = 0;
        #50 rst_n = 1;

        $display("=== Test 1: cold miss + refill ===");
        do_read(32'h0000_1000, backing_word(32'h0000_1000));

        $display("=== Test 2: same-line read should HIT ===");
        do_read(32'h0000_1004, backing_word(32'h0000_1004));

        $display("=== Test 3: write hit + read-back ===");
        do_write(32'h0000_1004, 32'hDEADBEEF, 4'hF);
        do_read (32'h0000_1004, 32'hDEADBEEF);

        $display("=== Test 4: byte-enable store ===");
        tmpw = backing_word(32'h0000_1008);
        do_write(32'h0000_1008, 32'hAABBCCDD, 4'b0011);
        expw = { tmpw[31:16], 16'hCCDD };
        do_read(32'h0000_1008, expw);

        $display("=== Test 5: conflict-set eviction ===");
        do_read(32'h0000_0000, backing_word(32'h0000_0000));
        do_read(32'h0001_0000, backing_word(32'h0001_0000));
        do_read(32'h0002_0000, backing_word(32'h0002_0000));
        do_read(32'h0003_0000, backing_word(32'h0003_0000));
        do_read(32'h0004_0000, backing_word(32'h0004_0000));

        $display("=== Test 6: dirty-eviction writeback ===");
        do_write(32'h0000_2000, 32'hCAFEBABE, 4'hF);
        do_read (32'h0001_2000, backing_word(32'h0001_2000));
        do_read (32'h0002_2000, backing_word(32'h0002_2000));
        do_read (32'h0003_2000, backing_word(32'h0003_2000));
        do_read (32'h0004_2000, backing_word(32'h0004_2000));
        if (backing_word(32'h0000_2000) !== 32'hCAFEBABE) begin
            $display("FAIL: dirty writeback didn't reach memory (got %h)",
                     backing_word(32'h0000_2000));
            errors = errors + 1;
        end else begin
            $display("PASS: dirty writeback observed at memory");
        end

        $display("=== Test 7: re-read evicted dirty line ===");
        do_read(32'h0000_2000, 32'hCAFEBABE);

        #200;
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
