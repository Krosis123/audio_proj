
module top (
    input  logic clk,
    input  logic cpu_resetn,
    input  logic uart_rxd,
    output logic uart_txd
);

    // UART and sample assembler
    logic [7:0] rx_data;
    logic rx_valid;
    logic signed [15:0] sample;
    logic sample_valid;

    // Audio memory
    logic [7:0] wr_addr, rd_addr;
    logic [7:0] perm_step;         // Odd affine multiplier a
    logic [7:0] perm_offset;       // Affine offset b
    logic [7:0] perm_addr;         // (a*i + b) mod 256
    logic [7:0] output_index;      // Current index i
    logic [15:0] rd_data;
    logic [15:0] scrambled_rd_data;
    logic wr_en, rd_en, collect_valid;
    logic [7:0] buffer_wr_addr, buffer_rd_addr;
    logic [15:0] buffer_wr_data;

    // entropy stuff
    logic [19:0] entropy_fixed;
    logic [19:0] entropy_reg;
    logic entropy_valid;
    logic entropy_start;

    logic [7:0] entropy_read_index;

    // Energy and zero-crossing statistics
    logic [39:0] energy, energy_reg;
    logic energy_valid;

    logic [7:0] zcr, zcr_reg;
    logic zcr_valid;

    // Exact histogram (internal to entropy computation)
    logic [8:0] hist_unique_count;
    logic [8:0] unique_count_reg;
    logic hist_done;

    logic [8:0] hist_count;

    // UART transmitter
    logic [7:0] tx_data;
    logic tx_send, tx_busy;
    logic tx_half;
    logic [3:0] energy_index;


typedef enum logic [4:0] {
    COLLECT,
    WAIT_ENERGY,
    WAIT_HIST,
    ENTROPY_START,
    WAIT_ENTROPY,

    SCRAMBLE_READ_REQ,
    SCRAMBLE_READ_WAIT,
    SCRAMBLE_STORE,
    INVERSE_READ_REQ,
    INVERSE_READ_WAIT,
    INVERSE_STORE,

    READ_REQ,
    READ_WAIT,
    START_TX,
    WAIT_TX_BUSY,
    WAIT_TX_DONE
} state_t;


    state_t state;

    // Which part of the response are we sending?
    typedef enum logic [1:0] {
        PH_AUDIO,
        PH_STATS,
        PH_COUNT
    } phase_t;

    phase_t phase;

    // Never feed restored writes back into the feature calculators.
    assign collect_valid = (state == COLLECT) && sample_valid;
    assign wr_en = collect_valid || (state == INVERSE_STORE);
    assign rd_en = (state == SCRAMBLE_READ_REQ) || (state == READ_REQ);

    // One original-audio memory handles collection, permutation reads,
    // inverse writes, and transmission of restored samples.
    assign buffer_wr_addr = (state == INVERSE_STORE) ? perm_addr : wr_addr;
    assign buffer_wr_data = (state == INVERSE_STORE) ? scrambled_rd_data : sample;
    assign buffer_rd_addr = (state == SCRAMBLE_READ_REQ) ? perm_addr : rd_addr;

    uart_rx receiver (
        .clk(clk),
        .reset_n(cpu_resetn),
        .rx(uart_rxd),
        .data(rx_data),
        .data_valid(rx_valid),
        .frame_error()
    );

    sample_assembler assembler (
        .clk(clk),
        .reset_n(cpu_resetn),
        .byte_data(rx_data),
        .byte_valid(rx_valid),
        .sample(sample),
        .sample_valid(sample_valid)
    );

    audio_buffer buffer_inst (
        .clk(clk),
        .wr_en(wr_en),
        .wr_addr(buffer_wr_addr),
        .wr_data(buffer_wr_data),
        .rd_en(rd_en),
        .rd_addr(buffer_rd_addr),
        .rd_data(rd_data)
    );

    // Scratch buffer: y[i] = x[(a*i+b) mod 256].
    // The inverse scatter then writes x[(a*i+b) mod 256] = y[i].
    audio_buffer scrambled_buffer_inst (
        .clk(clk),
        .wr_en(state == SCRAMBLE_STORE),
        .wr_addr(output_index),
        .wr_data(rd_data),
        .rd_en(state == INVERSE_READ_REQ),
        .rd_addr(output_index),
        .rd_data(scrambled_rd_data)
    );

    energy_calc calculator (
        .clk(clk),
        .reset_n(cpu_resetn),
        .sample_in(sample),
        .sample_valid(collect_valid),
        .energy(energy),
        .energy_valid(energy_valid)
    );

    zcr_calc zero_crossing (
        .clk(clk),
        .reset_n(cpu_resetn),
        .sample_in(sample),
        .sample_valid(collect_valid),
        .zcr(zcr),
        .zcr_valid(zcr_valid)
    );


assign entropy_start = (state == ENTROPY_START);

exact_histogram histogram (
    .clk(clk),
    .reset_n(cpu_resetn),
    .sample_in(sample),
    .sample_valid(collect_valid),
    .read_index(entropy_read_index),
    .read_value(),
    .read_count(hist_count),
    .unique_count(hist_unique_count),
    .hist_done(hist_done),
    .ready()
);




    entropy_calc entropy_unit (
        .clk(clk),
        .reset_n(cpu_resetn),

        .start(entropy_start),
        .unique_count(unique_count_reg),

        .read_index(entropy_read_index),
        .read_count(hist_count),

        .entropy_q16(entropy_fixed),
        .entropy_valid(entropy_valid)
    );


    uart_tx transmitter (
        .clk(clk),
        .reset_n(cpu_resetn),
        .send(tx_send),
        .data(tx_data),
        .tx(uart_txd),
        .busy(tx_busy)
    );

    always_ff @(posedge clk or negedge cpu_resetn) begin
        if (!cpu_resetn) begin
            state <= COLLECT;
            phase <= PH_AUDIO;
            wr_addr <= 0;
            rd_addr <= 0;
            perm_step <= 8'd1;
            perm_offset <= 8'd0;
            perm_addr <= 8'd0;
            output_index <= 0;
            entropy_reg <= 20'd0;
            tx_data <= 0;
            tx_send <= 0;
            tx_half <= 0;

            energy_reg <= 0;
            zcr_reg <= 0;
            energy_index <= 0;

            unique_count_reg <= 0;
        end
        else begin
            tx_send <= 0;

            case (state)

                COLLECT: begin
                    if (sample_valid) begin
                        if (wr_addr == 8'd255)
                            state <= WAIT_ENERGY;
                        else
                            wr_addr <= wr_addr + 1'b1;
                    end
                end

                WAIT_ENERGY: begin
                    if (energy_valid && zcr_valid) begin
                        energy_reg <= energy;
                        zcr_reg <= zcr;
                        state <= WAIT_HIST;
                    end
                end


                WAIT_HIST: begin
                    if (hist_done) begin
                        unique_count_reg <= hist_unique_count;
                        state <= ENTROPY_START;
                    end
                end

                ENTROPY_START: begin
                    state <= WAIT_ENTROPY;
                end

                WAIT_ENTROPY: begin
                    if (entropy_valid) begin
                        entropy_reg <= entropy_fixed;

                        // pi(i) = (a*i + b) mod 256, with odd a.
                        // Retain original features through the entire round trip.
                        perm_step <= (zcr_reg ^ entropy_fixed[7:0]) | 8'h01;
                        perm_offset <= energy_reg[7:0] ^ entropy_fixed[15:8];
                        perm_addr <= energy_reg[7:0] ^ entropy_fixed[15:8];
                        output_index <= 8'd0;

                        state <= SCRAMBLE_READ_REQ;
                    end
                end

                // Pass 1: read original x[pi(i)], write scratch y[i].
                // Registered buffer reads need a wait cycle.
                SCRAMBLE_READ_REQ: begin
                    state <= SCRAMBLE_READ_WAIT;
                end

                SCRAMBLE_READ_WAIT: begin
                    state <= SCRAMBLE_STORE;
                end

                SCRAMBLE_STORE: begin
                    // The scratch memory writes rd_data at output_index.
                    if (output_index == 8'd255) begin
                        output_index <= 8'd0;
                        perm_addr <= perm_offset;
                        state <= INVERSE_READ_REQ;
                    end
                    else begin
                        output_index <= output_index + 8'd1;
                        perm_addr <= perm_addr + perm_step;
                        state <= SCRAMBLE_READ_REQ;
                    end
                end

                // Pass 2: read scratch y[i], write original x[pi(i)].
                // No modular inverse or multiplier is needed.
                INVERSE_READ_REQ: begin
                    state <= INVERSE_READ_WAIT;
                end

                INVERSE_READ_WAIT: begin
                    state <= INVERSE_STORE;
                end

                INVERSE_STORE: begin
                    // Original memory writes scrambled_rd_data at perm_addr.
                    if (output_index == 8'd255) begin
                        rd_addr <= 8'd0;
                        phase <= PH_AUDIO;
                        tx_half <= 1'b0;
                        state <= READ_REQ;
                    end
                    else begin
                        output_index <= output_index + 8'd1;
                        perm_addr <= perm_addr + perm_step;
                        state <= INVERSE_READ_REQ;
                    end
                end

                READ_REQ: begin
                    state <= READ_WAIT;
                end

                READ_WAIT: begin
                    state <= START_TX;
                end

                START_TX: begin
                    if (!tx_busy) begin
                        case (phase)

                            PH_AUDIO: begin
                                tx_data <= tx_half ?
                                    rd_data[15:8] :
                                    rd_data[7:0];
                            end


                            PH_STATS: begin
                                case (energy_index)

                                    4'd0: tx_data <= energy_reg[7:0];
                                    4'd1: tx_data <= energy_reg[15:8];
                                    4'd2: tx_data <= energy_reg[23:16];
                                    4'd3: tx_data <= energy_reg[31:24];
                                    4'd4: tx_data <= energy_reg[39:32];

                                    4'd5: tx_data <= zcr_reg;

                                    4'd6: tx_data <= entropy_reg[7:0];
                                    4'd7: tx_data <= entropy_reg[15:8];
                                    4'd8: tx_data <= {4'b0, entropy_reg[19:16]};

                                    default: tx_data <= 8'd0;

                                endcase
                            end


                            PH_COUNT: begin
                                tx_data <= tx_half ?
                                    {7'b0, unique_count_reg[8]} :
                                    unique_count_reg[7:0];
                            end

                            default: tx_data <= 0;
                        endcase

                        tx_send <= 1;
                        state <= WAIT_TX_BUSY;
                    end
                end

                WAIT_TX_BUSY: begin
                    if (tx_busy)
                        state <= WAIT_TX_DONE;
                end

                WAIT_TX_DONE: begin
                    if (!tx_busy) begin
                        case (phase)

                            PH_AUDIO: begin
                                if (!tx_half) begin
                                    tx_half <= 1;
                                    state <= START_TX;
                                end
                                else if (rd_addr == 8'd255) begin
                                    // Last restored sample has been transmitted.
                                    phase <= PH_STATS;
                                    energy_index <= 0;
                                    state <= START_TX;
                                end
                                else begin
                                    rd_addr <= rd_addr + 8'd1;
                                    tx_half <= 0;
                                    state <= READ_REQ;
                                end
                            end

                            PH_STATS: begin
                                if (energy_index == 4'd8) begin
                                    phase <= PH_COUNT;
                                    tx_half <= 0;
                                end
                                else
                                    energy_index <= energy_index + 1'b1;

                                state <= START_TX;
                            end



                            PH_COUNT: begin
                                if (!tx_half) begin
                                    // Low byte of unique_count has finished
                                    tx_half <= 1'b1;
                                    state <= START_TX;
                                end
                                else begin
                                    // High byte finished: block is complete
                                    tx_half <= 1'b0;
                                    wr_addr <= 8'd0;
                                    rd_addr <= 8'd0;
                                    phase <= PH_AUDIO;
                                    state <= COLLECT;
                                end
                            end

                            default: state <= COLLECT;

                        endcase
                    end
                end

                default: state <= COLLECT;

            endcase
        end
    end

endmodule
