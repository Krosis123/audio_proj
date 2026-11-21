
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
    logic [15:0] rd_data;
    logic wr_en, rd_en;

    // entropy stuff
    logic [19:0] entropy_fixed;
    logic [19:0] entropy_reg;
    logic entropy_valid;
    logic entropy_start;

    logic [7:0] entropy_read_index;
    logic [7:0] histogram_read_addr;

    // Energy and zero-crossing statistics
    logic [39:0] energy, energy_reg;
    logic energy_valid;

    logic [7:0] zcr, zcr_reg;
    logic zcr_valid;

    // Exact histogram
    logic [8:0] hist_unique_count;
    logic [8:0] unique_count_reg;
    logic hist_done;

    logic [7:0] hist_index;
    logic [15:0] hist_value;
    logic [8:0] hist_count;
    logic [1:0] hist_byte_index;

    // UART transmitter
    logic [7:0] tx_data;
    logic tx_send, tx_busy;
    logic tx_half;
    logic [3:0] energy_index;


typedef enum logic [3:0] {
    COLLECT,
    WAIT_ENERGY,
    WAIT_HIST,
    ENTROPY_START,
    WAIT_ENTROPY,
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
        PH_COUNT,
        PH_HIST
    } phase_t;

    phase_t phase;

    assign wr_en = (state == COLLECT) && sample_valid;
    assign rd_en = (state == READ_REQ);

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
        .wr_addr(wr_addr),
        .wr_data(sample),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    energy_calc calculator (
        .clk(clk),
        .reset_n(cpu_resetn),
        .sample_in(sample),
        .sample_valid(wr_en),
        .energy(energy),
        .energy_valid(energy_valid)
    );

    zcr_calc zero_crossing (
        .clk(clk),
        .reset_n(cpu_resetn),
        .sample_in(sample),
        .sample_valid(wr_en),
        .zcr(zcr),
        .zcr_valid(zcr_valid)
    );

    exact_histogram histogram (

    assign entropy_start = (state == ENTROPY_START);

    assign histogram_read_addr =
        (state == ENTROPY_START ||
        state == WAIT_ENTROPY)
        ? entropy_read_index
        : hist_index;
        .clk(clk),
        .reset_n(cpu_resetn),
        .sample_in(sample),
        .sample_valid(wr_en),
        .read_index(histogram_read_addr),
        .read_value(hist_value),
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

            tx_data <= 0;
            tx_send <= 0;
            tx_half <= 0;

            energy_reg <= 0;
            zcr_reg <= 0;
            energy_index <= 0;

            hist_index <= 0;
            hist_byte_index <= 0;
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
                        phase <= PH_AUDIO;
                        rd_addr <= 0;
                        tx_half <= 0;
                        state <= READ_REQ;
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
                                    3'd0: tx_data <= energy_reg[7:0];
                                    3'd1: tx_data <= energy_reg[15:8];
                                    3'd2: tx_data <= energy_reg[23:16];
                                    3'd3: tx_data <= energy_reg[31:24];
                                    3'd4: tx_data <= energy_reg[39:32];
                                    3'd5: tx_data <= zcr_reg;
                                    default: tx_data <= 0;
                                endcase
                            end

                            PH_COUNT: begin
                                tx_data <= tx_half ?
                                    {7'b0, unique_count_reg[8]} :
                                    unique_count_reg[7:0];
                            end

                            PH_HIST: begin
                                case (hist_byte_index)
                                    2'd0: tx_data <= hist_value[7:0];
                                    2'd1: tx_data <= hist_value[15:8];
                                    2'd2: tx_data <= hist_count[7:0];
                                    2'd3: tx_data <= {7'b0, hist_count[8]};
                                endcase
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
                                    phase <= PH_STATS;
                                    energy_index <= 0;
                                    state <= START_TX;
                                end
                                else begin
                                    rd_addr <= rd_addr + 1'b1;
                                    tx_half <= 0;
                                    state <= READ_REQ;
                                end
                            end

                            PH_STATS: begin
                                if (energy_index == 3'd5) begin
                                    phase <= PH_COUNT;
                                    tx_half <= 0;
                                end
                                else
                                    energy_index <= energy_index + 1'b1;

                                state <= START_TX;
                            end

                            PH_COUNT: begin
                                if (!tx_half) begin
                                    tx_half <= 1;
                                end
                                else begin
                                    phase <= PH_HIST;
                                    hist_index <= 0;
                                    hist_byte_index <= 0;
                                end

                                state <= START_TX;
                            end

                            PH_HIST: begin
                                if (hist_byte_index != 2'd3) begin
                                    hist_byte_index <=
                                        hist_byte_index + 1'b1;

                                    state <= START_TX;
                                end
                                else if (
                                    ({1'b0, hist_index} + 9'd1)
                                    == unique_count_reg
                                ) begin
                                    // Complete block transmitted
                                    wr_addr <= 0;
                                    rd_addr <= 0;
                                    phase <= PH_AUDIO;
                                    state <= COLLECT;
                                end
                                else begin
                                    hist_index <= hist_index + 1'b1;
                                    hist_byte_index <= 0;
                                    state <= READ_WAIT;
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
