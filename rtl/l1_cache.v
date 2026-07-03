// =============================================================================
//  l1_cache.v — Parameterized VIPT L1 cache controller
//  Features:
//    * Virtually Indexed, Physically Tagged (VIPT)
//    * Configurable capacity, line size, associativity, page size
//    * Write-back + write-allocate
//    * Tree-PLRU (for WAYS=4) or NRU (any WAYS)
//    * Critical-word-first refill (compile-time switch)
//    * Reset-walk FSM that clears valid bits over (SETS) cycles
//    * Byte-enable stores
//    * Line-wide or word-wide memory bus (parameterized)
//
//  VIPT no-alias invariant:
//      INDEX_BITS + OFFSET_BITS <= log2(PAGE_B)
//  i.e. CACHE_SIZE / WAYS <= PAGE_B  (one way fits in one page)
//
//  Author: cache-run project, 2026
// =============================================================================
`default_nettype none

module l1_cache #(
    // ---------- design knobs (sweep these) ----------
    parameter ADDR_W      = 32,    // address width in bits
    parameter DATA_W      = 32,    // CPU word width
    parameter LINE_B      = 64,    // line/block size in bytes
    parameter SETS        = 64,    // number of sets
    parameter WAYS        = 4,     // associativity
    parameter PAGE_B      = 4096,  // page size in bytes (for VIPT alias check)
    parameter REPL        = 0,     // 0=Tree-PLRU (only WAYS==4), 1=NRU
    parameter CWF         = 1,     // critical-word-first refill
    parameter BUS_BEAT_W  = 32     // memory bus beat width in bits
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- CPU request port ----
    input  wire                cpu_req,        // request valid
    input  wire                cpu_we,         // 1=write, 0=read
    input  wire [ADDR_W-1:0]   cpu_vaddr,      // virtual address (used for index)
    input  wire [ADDR_W-1:0]   cpu_paddr,      // physical address from TLB (same cycle)
    input  wire [DATA_W-1:0]   cpu_wdata,
    input  wire [DATA_W/8-1:0] cpu_be,         // byte enables
    output reg                 cpu_ready,
    output reg  [DATA_W-1:0]   cpu_rdata,
    output reg                 cpu_rvalid,

    // ---- Memory (next-level) port: simple beat-handshake ----
    output reg                 mem_req,
    output reg                 mem_we,
    output reg  [ADDR_W-1:0]   mem_addr,
    output reg  [BUS_BEAT_W-1:0] mem_wdata,
    input  wire                mem_gnt,
    input  wire                mem_rvalid,
    input  wire [BUS_BEAT_W-1:0] mem_rdata
);

    // ---------- derived geometry ----------
    localparam OFFSET_B = $clog2(LINE_B);
    localparam INDEX_B  = $clog2(SETS);
    localparam TAG_B    = ADDR_W - INDEX_B - OFFSET_B;
    localparam WAY_B    = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam WORD_B   = DATA_W/8;
    localparam WORDS_PER_LINE = LINE_B / WORD_B;
    localparam WORDIDX_B = (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;
    localparam BEATS_PER_LINE = (LINE_B*8) / BUS_BEAT_W;
    localparam BEATIDX_B = (BEATS_PER_LINE > 1) ? $clog2(BEATS_PER_LINE) : 1;
    localparam BUS_BYTE_W = BUS_BEAT_W/8;

    // ---------- compile-time sanity ----------
    initial begin
        if ((SETS * LINE_B) > PAGE_B) begin
            $display("INFO: VIPT alias-risk: SETS*LINE_B=%0d > PAGE_B=%0d. Need page coloring or PIPT.",
                     SETS*LINE_B, PAGE_B);
        end
        if (REPL == 0 && WAYS != 4) begin
            $display("ERROR: REPL=0 (Tree-PLRU) only supported for WAYS=4. Got WAYS=%0d.", WAYS);
            $finish;
        end
        if (LINE_B*8 % BUS_BEAT_W != 0) begin
            $display("ERROR: LINE_B*8=%0d not a multiple of BUS_BEAT_W=%0d.", LINE_B*8, BUS_BEAT_W);
            $finish;
        end
        $display("[l1_cache] C=%0dB B=%0dB K=%0d S=%0d TAG=%0d INDEX=%0d OFFSET=%0d BEATS=%0d REPL=%0d CWF=%0d",
                 SETS*WAYS*LINE_B, LINE_B, WAYS, SETS, TAG_B, INDEX_B, OFFSET_B, BEATS_PER_LINE, REPL, CWF);
    end

    // ---------- storage arrays ----------
    reg [TAG_B-1:0]   tag_arr   [0:WAYS-1][0:SETS-1];
    reg               valid_arr [0:WAYS-1][0:SETS-1];
    reg               dirty_arr [0:WAYS-1][0:SETS-1];
    reg [DATA_W-1:0]  data_arr  [0:WAYS-1][0:SETS-1][0:WORDS_PER_LINE-1];

    // PLRU bits (3 per set, for WAYS=4)
    reg [2:0]         plru      [0:SETS-1];
    // NRU bits (one per way per set, for arbitrary WAYS)
    reg [WAYS-1:0]    nru       [0:SETS-1];

    // ---------- address decomposition for the live request ----------
    wire [OFFSET_B-1:0]  req_off   = cpu_vaddr[OFFSET_B-1:0];
    wire [INDEX_B-1:0]   req_idx   = cpu_vaddr[OFFSET_B +: INDEX_B];
    wire [TAG_B-1:0]     req_tag   = cpu_paddr[ADDR_W-1 -: TAG_B];
    wire [WORDIDX_B-1:0] req_word  = (WORDS_PER_LINE>1) ? req_off[OFFSET_B-1 -: WORDIDX_B] : 1'b0;

    // ---------- hit detection (combinational) ----------
    wire [WAYS-1:0] match;
    genvar gw;
    generate
        for (gw=0; gw<WAYS; gw=gw+1) begin: g_match
            assign match[gw] = valid_arr[gw][req_idx]
                            && (tag_arr[gw][req_idx] == req_tag);
        end
    endgenerate

    wire        hit = |match;

    // priority-encode the matching way
    integer i_pe;
    reg [WAY_B-1:0] hit_way;
    always @(*) begin
        hit_way = {WAY_B{1'b0}};
        for (i_pe = WAYS-1; i_pe >= 0; i_pe = i_pe - 1) begin
            if (match[i_pe]) hit_way = i_pe[WAY_B-1:0];
        end
    end

    // ---------- victim selection (combinational) ----------
    // Prefer invalid; else use replacement policy.
    function automatic [WAY_B-1:0] plru4_victim;
        input [2:0] b;
        begin
            plru4_victim = (b[2]==1'b0)
                         ? ((b[1]==1'b0) ? 2'd0 : 2'd1)
                         : ((b[0]==1'b0) ? 2'd2 : 2'd3);
        end
    endfunction

    reg [WAY_B-1:0] victim_way;
    integer i_v;
    always @(*) begin
        victim_way = {WAY_B{1'b0}};
        // search for an invalid way
        for (i_v = WAYS-1; i_v >= 0; i_v = i_v - 1) begin
            if (!valid_arr[i_v][req_idx]) victim_way = i_v[WAY_B-1:0];
        end
        if (&{ valid_arr[0][req_idx],
               (WAYS>1) ? valid_arr[(WAYS>1)?1:0][req_idx] : 1'b1,
               (WAYS>2) ? valid_arr[(WAYS>2)?2:0][req_idx] : 1'b1,
               (WAYS>3) ? valid_arr[(WAYS>3)?3:0][req_idx] : 1'b1 }) begin
            // all-valid (approx for WAYS<=4)
            if (REPL == 0) begin
                victim_way = plru4_victim(plru[req_idx]);
            end else begin
                // NRU: any way whose NRU bit is 0
                victim_way = {WAY_B{1'b0}};
                for (i_v = WAYS-1; i_v >= 0; i_v = i_v - 1) begin
                    if (nru[req_idx][i_v] == 1'b0) victim_way = i_v[WAY_B-1:0];
                end
            end
        end
    end

    // ---------- PLRU / NRU update procedures ----------
    task automatic plru_touch(input [INDEX_B-1:0] s, input [WAY_B-1:0] w);
        begin
            if (REPL == 0) begin
                // Tree-PLRU update — flip path AWAY from accessed way
                if (w[1]==1'b0) begin
                    plru[s][2] <= 1'b1;
                    plru[s][1] <= ~w[0];
                end else begin
                    plru[s][2] <= 1'b0;
                    plru[s][0] <= ~w[0];
                end
            end else begin
                // NRU update — set the bit; if all bits become 1, clear them next cycle
                nru[s][w] <= 1'b1;
                if (&(nru[s] | (({{(WAYS-1){1'b0}}, 1'b1}) << w))) begin
                    nru[s] <= ({{(WAYS-1){1'b0}}, 1'b1}) << w;
                end
            end
        end
    endtask

    // ---------- FSM ----------
    localparam S_RESET    = 4'd0;
    localparam S_IDLE     = 4'd1;
    localparam S_WB_ISSUE = 4'd2;
    localparam S_WB_BEAT  = 4'd3;
    localparam S_RF_ISSUE = 4'd4;
    localparam S_RF_BEAT  = 4'd5;
    localparam S_INSTALL  = 4'd6;

    reg [3:0] state;

    // latched request
    reg               p_we;
    reg [ADDR_W-1:0]  p_vaddr, p_paddr;
    reg [DATA_W-1:0]  p_wdata;
    reg [DATA_W/8-1:0] p_be;
    reg [TAG_B-1:0]   p_tag;
    reg [INDEX_B-1:0] p_idx;
    reg [WORDIDX_B-1:0] p_word;
    reg [WAY_B-1:0]   p_victim;
    reg [TAG_B-1:0]   p_victim_tag;
    reg               p_victim_dirty;

    // beat counter
    reg [BEATIDX_B:0] beat_cnt;
    reg [BEATIDX_B:0] cwf_start;   // critical beat for CWF refill

    // reset counter
    reg [INDEX_B-1:0] rst_cnt;

    // line refill buffer (collected across BEATS_PER_LINE beats)
    reg [LINE_B*8-1:0] refill_buf;

    integer wi;

    // ---------- main sequential ----------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_RESET;
            rst_cnt    <= 0;
            mem_req    <= 1'b0;
            mem_we     <= 1'b0;
            cpu_ready  <= 1'b0;
            cpu_rvalid <= 1'b0;
            beat_cnt   <= 0;
        end else begin
            cpu_rvalid <= 1'b0;

            case (state)
                // ----- reset: walk index, clear valids -----
                S_RESET: begin
                    for (wi = 0; wi < WAYS; wi = wi + 1) begin
                        valid_arr[wi][rst_cnt] <= 1'b0;
                        dirty_arr[wi][rst_cnt] <= 1'b0;
                    end
                    plru[rst_cnt] <= 3'b000;
                    nru[rst_cnt]  <= {WAYS{1'b0}};
                    if (rst_cnt == SETS-1) begin
                        state     <= S_IDLE;
                        cpu_ready <= 1'b1;
                    end else begin
                        rst_cnt <= rst_cnt + 1'b1;
                    end
                end

                // ----- idle / accept new request -----
                S_IDLE: begin
                    if (cpu_req) begin
                        if (hit) begin
                            // ---- HIT ----
                            if (cpu_we) begin
                                for (wi = 0; wi < DATA_W/8; wi = wi + 1) begin
                                    if (cpu_be[wi]) begin
                                        data_arr[hit_way][req_idx][req_word][wi*8 +: 8] <= cpu_wdata[wi*8 +: 8];
                                    end
                                end
                                dirty_arr[hit_way][req_idx] <= 1'b1;
                            end else begin
                                cpu_rdata  <= data_arr[hit_way][req_idx][req_word];
                                cpu_rvalid <= 1'b1;
                            end
                            plru_touch(req_idx, hit_way);
                            // stay in IDLE, ready remains high
                        end else begin
                            // ---- MISS ----
                            p_we         <= cpu_we;
                            p_vaddr      <= cpu_vaddr;
                            p_paddr      <= cpu_paddr;
                            p_wdata      <= cpu_wdata;
                            p_be         <= cpu_be;
                            p_tag        <= req_tag;
                            p_idx        <= req_idx;
                            p_word       <= req_word;
                            p_victim     <= victim_way;
                            p_victim_tag <= tag_arr[victim_way][req_idx];
                            p_victim_dirty <= valid_arr[victim_way][req_idx]
                                              && dirty_arr[victim_way][req_idx];
                            beat_cnt     <= 0;
                            cpu_ready    <= 1'b0;
                            // pre-compute critical-word starting beat
                            cwf_start    <= (CWF) ? (req_off >> $clog2(BUS_BYTE_W)) : 0;

                            if (valid_arr[victim_way][req_idx]
                                && dirty_arr[victim_way][req_idx]) begin
                                // dirty victim → writeback first
                                state    <= S_WB_ISSUE;
                            end else begin
                                state    <= S_RF_ISSUE;
                            end
                        end
                    end
                end

                // ----- writeback path -----
                S_WB_ISSUE: begin
                    mem_req   <= 1'b1;
                    mem_we    <= 1'b1;
                    mem_addr  <= { p_victim_tag, p_idx, {OFFSET_B{1'b0}} }
                                 + (beat_cnt * BUS_BYTE_W);
                    // pack the appropriate beat of the dirty line into mem_wdata
                    mem_wdata <= pick_beat(p_victim, p_idx, beat_cnt);
                    state     <= S_WB_BEAT;
                end

                S_WB_BEAT: begin
                    if (mem_gnt) begin
                        mem_req <= 1'b0;
                        if (beat_cnt == BEATS_PER_LINE-1) begin
                            // writeback complete
                            dirty_arr[p_victim][p_idx] <= 1'b0;
                            beat_cnt <= 0;
                            state    <= S_RF_ISSUE;
                        end else begin
                            beat_cnt <= beat_cnt + 1'b1;
                            state    <= S_WB_ISSUE;
                        end
                    end
                end

                // ----- refill path -----
                S_RF_ISSUE: begin
                    mem_req  <= 1'b1;
                    mem_we   <= 1'b0;
                    mem_addr <= { p_paddr[ADDR_W-1:OFFSET_B], {OFFSET_B{1'b0}} }
                                + ( ((beat_cnt + cwf_start) % BEATS_PER_LINE) * BUS_BYTE_W );
                    state    <= S_RF_BEAT;
                end

                S_RF_BEAT: begin
                    if (mem_gnt) begin
                        mem_req <= 1'b0;
                    end
                    if (mem_rvalid) begin
                        // shift returning beat into refill_buf at its proper place
                        refill_buf[ ((beat_cnt + cwf_start) % BEATS_PER_LINE)
                                    * BUS_BEAT_W +: BUS_BEAT_W ] <= mem_rdata;
                        if (beat_cnt == BEATS_PER_LINE-1) begin
                            state    <= S_INSTALL;
                            beat_cnt <= 0;
                        end else begin
                            beat_cnt <= beat_cnt + 1'b1;
                            state    <= S_RF_ISSUE;
                        end
                    end
                end

                // ----- install the refilled line -----
                S_INSTALL: begin
                    // Write the refilled data into the data array
                    for (wi = 0; wi < WORDS_PER_LINE; wi = wi + 1) begin
                        data_arr[p_victim][p_idx][wi] <=
                            refill_buf[wi*DATA_W +: DATA_W];
                    end
                    tag_arr  [p_victim][p_idx] <= p_tag;
                    valid_arr[p_victim][p_idx] <= 1'b1;
                    dirty_arr[p_victim][p_idx] <= 1'b0;

                    // Merge pending store if write miss, OR forward load value
                    if (p_we) begin
                        for (wi = 0; wi < DATA_W/8; wi = wi + 1) begin
                            if (p_be[wi]) begin
                                data_arr[p_victim][p_idx][p_word][wi*8 +: 8]
                                    <= p_wdata[wi*8 +: 8];
                            end
                        end
                        dirty_arr[p_victim][p_idx] <= 1'b1;
                    end else begin
                        cpu_rdata  <= refill_buf[p_word*DATA_W +: DATA_W];
                        cpu_rvalid <= 1'b1;
                    end

                    plru_touch(p_idx, p_victim);
                    cpu_ready <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------- helper: pick beat of a line for writeback ----------
    function automatic [BUS_BEAT_W-1:0] pick_beat;
        input [WAY_B-1:0]    w;
        input [INDEX_B-1:0]  s;
        input [BEATIDX_B:0]  beat;
        integer wj;
        reg [LINE_B*8-1:0] line_concat;
        begin
            for (wj = 0; wj < WORDS_PER_LINE; wj = wj + 1) begin
                line_concat[wj*DATA_W +: DATA_W] = data_arr[w][s][wj];
            end
            pick_beat = line_concat[beat*BUS_BEAT_W +: BUS_BEAT_W];
        end
    endfunction

endmodule

`default_nettype wire
