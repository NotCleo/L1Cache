module vipt_l1_cache #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter OFFSET_BITS = 4,      // block size = 2^OFFSET_BITS bytes
    parameter INDEX_BITS  = 6       // number of sets = 2^INDEX_BITS
)(
    input                   clk,
    input                   reset_n,

    // CPU-side interface
    input                   cpu_req,         // request valid (single-cycle pulse or held until ready)
    input                   cpu_write,       // 1 = store, 0 = load
    input  [ADDR_WIDTH-1:0] cpu_virt_addr,   // virtual address (used for index)
    input  [ADDR_WIDTH-1:0] cpu_phys_addr,   // physical address (used for tag)
    input  [DATA_WIDTH-1:0] cpu_wdata,
    output                  cpu_ready,       // cache ready to accept new request (combinational)
    output [DATA_WIDTH-1:0] cpu_rdata,
    output                  cpu_miss,        // asserted while miss is being serviced

    // Simple memory interface (single-word handshake)
    output                  mem_req,         // request to memory (valid)
    output                  mem_write,       // 1 => write (writeback), 0 => read (fetch)
    output [ADDR_WIDTH-1:0] mem_addr,        // word address (aligned by word)
    output [DATA_WIDTH-1:0] mem_wdata,       // word to write for writeback
    input                   mem_ready,       // memory accepted request
    input                   mem_resp_valid,  // memory provided read data (valid)
    input  [DATA_WIDTH-1:0] mem_rdata        // read data returned
);

    // Local parameters
    parameter ASSOC = 4;
    parameter BYTES_PER_WORD = DATA_WIDTH/8;
    parameter BLOCK_BYTES = (1 << OFFSET_BITS);
    parameter WORDS_PER_BLOCK = BLOCK_BYTES / BYTES_PER_WORD;
    parameter SETS = (1 << INDEX_BITS);
    parameter TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    parameter WAY_BITS = 2; // 4 ways -> 2 bits

    // Derived signals
    wire [OFFSET_BITS-1:0] offset = cpu_virt_addr[OFFSET_BITS-1:0];
    wire [INDEX_BITS-1:0]  index  = cpu_virt_addr[OFFSET_BITS +: INDEX_BITS]; // note: some tools accept [OFFSET_BITS + INDEX_BITS -1 : OFFSET_BITS]
    // For maximum compatibility, we use explicit range:
    // physical tag is bits [ADDR_WIDTH-1 : OFFSET_BITS+INDEX_BITS]
    wire [TAG_BITS-1:0] phys_tag = cpu_phys_addr[ADDR_WIDTH-1:OFFSET_BITS+INDEX_BITS];

    // word index inside block
    integer _wl;
    reg [clog2(WORDS_PER_BLOCK)-1:0] word_index_unused; // placeholder to satisfy old tools (not used)
    // But Verilog does not have clog2 as function; we'll compute word index as slice:
    // If WORDS_PER_BLOCK > 1, word_index_width = $clog2(WORDS_PER_BLOCK)
    // To avoid $clog2 usage in port widths, we compute index by slicing offset.
    // For example, if OFFSET_BITS=4 and WORDS_PER_BLOCK=4 (DATA_WIDTH=32 => 4 bytes/word -> words_per_block=4), word_index is offset[3:2].

    // compute word index slice bounds
    function integer _log2;
        input integer val;
        integer i;
        begin
            _log2 = 0;
            for (i = val-1; i > 0; i = i >> 1)
                _log2 = _log2 + 1;
        end
    endfunction
    localparam WORDIDX_BITS = (_log2(WORDS_PER_BLOCK) == 0) ? 1 : _log2(WORDS_PER_BLOCK);

    wire [WORDIDX_BITS-1:0] word_index;
    assign word_index = (WORDS_PER_BLOCK == 1) ? {WORDIDX_BITS{1'b0}} : offset[OFFSET_BITS-1 -: WORDIDX_BITS];

    // Storage arrays (synthesizable behavioral RAMs)
    // Dimensions: [way][set] for tags/valid/dirty, [way][set][word] for data words in block
    reg [TAG_BITS-1:0] tag_array [0:ASSOC-1][0:SETS-1];
    reg               valid_array [0:ASSOC-1][0:SETS-1];
    reg               dirty_array [0:ASSOC-1][0:SETS-1];
    reg [DATA_WIDTH-1:0] data_array [0:ASSOC-1][0:SETS-1][0:WORDS_PER_BLOCK-1];

    // PLRU bits per set: 3 bits per set (tree-based): [2]=root, [1]=left, [0]=right
    reg [2:0] plru [0:SETS-1];

    integer i, j, k;

    // Hit detection (combinational)
    reg [ASSOC-1:0] way_match;
    reg hit;
    reg [WAY_BITS-1:0] hit_way;
    always @(*) begin
        way_match = {ASSOC{1'b0}};
        hit = 1'b0;
        hit_way = {WAY_BITS{1'b0}};
        for (i = 0; i < ASSOC; i = i + 1) begin
            if (valid_array[i][index] && (tag_array[i][index] == phys_tag)) begin
                way_match[i] = 1'b1;
                hit = 1'b1;
                hit_way = i[WAY_BITS-1:0];
            end else begin
                way_match[i] = 1'b0;
            end
        end
    end

    // PLRU select function (tree)
    function [WAY_BITS-1:0] plru_select;
        input [2:0] bits;
        begin
            // bits[2] root: 0->left subtree (ways 0/1), 1->right subtree (ways 2/3)
            if (bits[2] == 1'b0) begin
                if (bits[1] == 1'b0) plru_select = 2'd0;
                else plru_select = 2'd1;
            end else begin
                if (bits[0] == 1'b0) plru_select = 2'd2;
                else plru_select = 2'd3;
            end
        end
    endfunction

    // PLRU update task (procedural)
    task plru_update;
        input integer set_idx;
        input [WAY_BITS-1:0] way;
        begin
            if (way < 2) begin
                plru[set_idx][2] = 1'b0; // mark root to prefer right next time
                plru[set_idx][1] = (way == 1) ? 1'b1 : 1'b0;
            end else begin
                plru[set_idx][2] = 1'b1; // mark root to prefer left next time
                plru[set_idx][0] = (way == 3) ? 1'b1 : 1'b0;
            end
        end
    endtask

    // victim selection: prefer invalid way, else PLRU
    reg [WAY_BITS-1:0] victim_way;
    task select_victim;
        input integer set_idx;
        output [WAY_BITS-1:0] v;
        begin
            if (!valid_array[0][set_idx]) v = 2'd0;
            else if (!valid_array[1][set_idx]) v = 2'd1;
            else if (!valid_array[2][set_idx]) v = 2'd2;
            else if (!valid_array[3][set_idx]) v = 2'd3;
            else v = plru_select(plru[set_idx]);
        end
    endtask

    // block aligned physical base address
    wire [ADDR_WIDTH-1:0] block_base_phys = { cpu_phys_addr[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}} };

    // memory interface registers
    reg mem_req_r;
    reg mem_write_r;
    reg [ADDR_WIDTH-1:0] mem_addr_r;
    reg [DATA_WIDTH-1:0] mem_wdata_r;

    assign mem_req = mem_req_r;
    assign mem_write = mem_write_r;
    assign mem_addr = mem_addr_r;
    assign mem_wdata = mem_wdata_r;

    // CPU outputs
    reg [DATA_WIDTH-1:0] cpu_rdata_r;
    reg cpu_miss_r;
    reg cpu_ready_r;

    assign cpu_rdata = cpu_rdata_r;
    assign cpu_miss = cpu_miss_r;
    assign cpu_ready = cpu_ready_r;

    // FSM states
    localparam IDLE = 3'd0;
    localparam EVICT_WAIT = 3'd1;
    localparam REFILL = 3'd2;
    localparam REFILL_WAIT = 3'd3;
    localparam RESPOND = 3'd4;

    reg [2:0] state;
    reg [2:0] next_state;

    // pending request storage
    reg pending_req;
    reg pending_write;
    reg [ADDR_WIDTH-1:0] pending_virt;
    reg [ADDR_WIDTH-1:0] pending_phys;
    reg [DATA_WIDTH-1:0] pending_wdata;

    // refill bookkeeping
    reg [WAY_BITS-1:0] refill_way;
    integer refill_word_cnt;

    // reset/init
    initial begin
        for (i = 0; i < ASSOC; i = i + 1) begin
            for (j = 0; j < SETS; j = j + 1) begin
                tag_array[i][j] = {TAG_BITS{1'b0}};
                valid_array[i][j] = 1'b0;
                dirty_array[i][j] = 1'b0;
                for (k = 0; k < WORDS_PER_BLOCK; k = k + 1)
                    data_array[i][j][k] = {DATA_WIDTH{1'b0}};
            end
        end
        for (i = 0; i < SETS; i = i + 1)
            plru[i] = 3'b000;
        mem_req_r = 1'b0;
        mem_write_r = 1'b0;
        mem_addr_r = {ADDR_WIDTH{1'b0}};
        mem_wdata_r = {DATA_WIDTH{1'b0}};
        cpu_rdata_r = {DATA_WIDTH{1'b0}};
        cpu_miss_r = 1'b0;
        cpu_ready_r = 1'b1;
        state = IDLE;
        pending_req = 1'b0;
    end

    // combinational next-state (kept simple)
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (pending_req) begin
                    if (hit) begin
                        next_state = RESPOND;
                    end else begin
                        // choose victim (combinational)
                        // victim_way will be computed in sequential upon entering miss handling
                        next_state = EVICT_WAIT;
                    end
                end
            end
            EVICT_WAIT: begin
                // when we issue writeback, wait until accepted (mem_ready clears mem_req_r)
                // or if victim not dirty, move immediately to REFILL
                if (!mem_req_r) begin
                    next_state = REFILL_WAIT;
                end
            end
            REFILL_WAIT: begin
                // waiting for memory to produce words via mem_resp_valid
                // we count words in sequential, move to RESPOND when done
                // keep in this state until refill_word_cnt completes
                next_state = REFILL_WAIT;
            end
            RESPOND: begin
                // after responding (completing the cpu operation) go back to IDLE
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // Main sequential FSM
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // reset registers
            mem_req_r <= 1'b0;
            mem_write_r <= 1'b0;
            mem_addr_r <= {ADDR_WIDTH{1'b0}};
            mem_wdata_r <= {DATA_WIDTH{1'b0}};
            cpu_rdata_r <= {DATA_WIDTH{1'b0}};
            cpu_miss_r <= 1'b0;
            cpu_ready_r <= 1'b1;
            pending_req <= 1'b0;
            state <= IDLE;
            refill_word_cnt <= 0;
        end else begin
            state <= next_state;

            // accept new CPU request if cpu_req asserted and cpu_ready
            if (cpu_req && cpu_ready_r) begin
                // latch request
                pending_req <= 1'b1;
                pending_write <= cpu_write;
                pending_virt <= cpu_virt_addr;
                pending_phys <= cpu_phys_addr;
                pending_wdata <= cpu_wdata;
                cpu_ready_r <= 1'b0; // will be set when operation completes
                cpu_miss_r <= 1'b0;
            end

            case (state)
                IDLE: begin
                    // if pending and hit -> respond (single-cycle)
                    if (pending_req && hit) begin
                        // On read: supply data; on write: update word and set dirty
                        if (pending_write) begin
                            data_array[hit_way][index][word_index] <= pending_wdata;
                            dirty_array[hit_way][index] <= 1'b1;
                        end
                        cpu_rdata_r <= data_array[hit_way][index][word_index];
                        // update PLRU
                        plru_update(index, hit_way);
                        // finish
                        pending_req <= 1'b0;
                        cpu_ready_r <= 1'b1;
                        cpu_miss_r <= 1'b0;
                    end else if (pending_req && !hit) begin
                        // MISS: select victim and possibly writeback
                        select_victim(index, victim_way);
                        refill_way <= victim_way;
                        // if victim valid and dirty -> issue writeback (word-by-word)
                        if (valid_array[victim_way][index] && dirty_array[victim_way][index]) begin
                            // start writeback of WORDS_PER_BLOCK words: we will issue mem_req per word
                            // set counters and issue first word
                            refill_word_cnt <= 0;
                            mem_req_r <= 1'b1;
                            mem_write_r <= 1'b1;
                            // compute victim block address: tag|index|offset(0)
                            mem_addr_r <= { tag_array[victim_way][index], index, {OFFSET_BITS{1'b0}} } + 0; // base
                            mem_wdata_r <= data_array[victim_way][index][0];
                            // mark we'll be in EVICT_WAIT
                            cpu_miss_r <= 1'b1;
                        end else begin
                            // no writeback needed -> request refill from memory
                            refill_word_cnt <= 0;
                            mem_req_r <= 1'b1;
                            mem_write_r <= 1'b0;
                            mem_addr_r <= { pending_phys[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}} } + 0; // base
                            cpu_miss_r <= 1'b1;
                        end
                    end
                end

                EVICT_WAIT: begin
                    // wait for memory to accept the mem_req (mem_ready)
                    if (mem_req_r && mem_ready) begin
                        // memory accepted this word; clear mem_req to allow next issuance on next cycle
                        mem_req_r <= 1'b0;
                    end

                    // If we previously issued a writeback (mem_write_r == 1) and mem_ready accepted:
                    if (!mem_req_r && mem_write_r) begin
                        // we finished one word of writeback; if not last, issue next word
                        refill_word_cnt = refill_word_cnt + 1;
                        if (refill_word_cnt < WORDS_PER_BLOCK) begin
                            // issue next writeback word
                            mem_req_r <= 1'b1;
                            mem_write_r <= 1'b1;
                            // address increments by word size
                            mem_addr_r <= { tag_array[refill_way][index], index, {OFFSET_BITS{1'b0}} } + (refill_word_cnt * BYTES_PER_WORD);
                            mem_wdata_r <= data_array[refill_way][index][refill_word_cnt];
                        end else begin
                            // writeback complete -> clear dirty, then start refill
                            dirty_array[refill_way][index] <= 1'b0;
                            // now prepare refill from pending_phys
                            refill_word_cnt <= 0;
                            mem_req_r <= 1'b1;
                            mem_write_r <= 1'b0;
                            mem_addr_r <= { pending_phys[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}} } + 0;
                        end
                    end else if (!mem_req_r && !mem_write_r) begin
                        // we issued a read (refill); next state will be REFILL_WAIT to collect mem_resp_valid words
                    end
                end

                REFILL_WAIT: begin
                    // This state path is merged with both EVICT_WAIT and REFILL_WAIT: we rely on mem_resp_valid to push words in.
                end

                RESPOND: begin
                    // not used in this simplified seq: all respond handled in-line
                end

                default: ;
            endcase

            // Handle incoming mem responses (mem_resp_valid). Refill words into data_array[refill_way][index][word_cnt]
            if (mem_resp_valid) begin
                // write returned word into data array at appropriate word index
                data_array[refill_way][index][refill_word_cnt] <= mem_rdata;
                // increment refill_word_cnt and either continue requesting next mem word or finish
                if (refill_word_cnt < (WORDS_PER_BLOCK - 1)) begin
                    refill_word_cnt <= refill_word_cnt + 1;
                    // issue next mem_req word (read)
                    mem_req_r <= 1'b1;
                    mem_write_r <= 1'b0;
                    // next word address:
                    mem_addr_r <= { pending_phys[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}} } + ((refill_word_cnt + 1) * BYTES_PER_WORD);
                end else begin
                    // refill complete: set tag/valid/dirty and finish CPU operation
                    tag_array[refill_way][index] <= pending_phys[ADDR_WIDTH-1:OFFSET_BITS];
                    valid_array[refill_way][index] <= 1'b1;
                    dirty_array[refill_way][index] <= 1'b0;
                    // If pending was a write, update word and mark dirty
                    if (pending_write) begin
                        data_array[refill_way][index][word_index] <= pending_wdata;
                        dirty_array[refill_way][index] <= 1'b1;
                    end
                    // update PLRU for this set
                    plru_update(index, refill_way);
                    // prepare return data for loads
                    cpu_rdata_r <= data_array[refill_way][index][word_index];
                    // clear pending and mark ready
                    pending_req <= 1'b0;
                    cpu_ready_r <= 1'b1;
                    cpu_miss_r <= 1'b0;
                    // ensure mem_req cleared
                    mem_req_r <= 1'b0;
                    mem_write_r <= 1'b0;
                end
            end

            // If mem_req_r is asserted and mem_ready is high, memory accepted request; clear mem_req_r
            if (mem_req_r && mem_ready) begin
                mem_req_r <= 1'b0;
                // for writeback we will step in EVICT_WAIT logic above
            end
        end
    end

    // For compatibility: warn if tools lack support for multi-dimensional arrays, users may adapt to single-dim flattened memories.
    // Note: synthesizable-ish behavioral cache; for FPGA inference replace arrays with explicit BRAMs.

endmodule
