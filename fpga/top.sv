
module top (
    input  logic clk,
    input  logic cpu_resetn,
    input  logic uart_rxd,
    output logic uart_txd
);

    logic [7:0] rx_data;
    logic rx_valid;

    logic signed [15:0] sample;
    logic sample_valid;


    logic [8:0] histogram_unique_count;
    logic histogram_done;
    logic histogram_ready;

    logic [7:0] histogram_read_index;
    logic [15:0] histogram_read_value;
    logic [8:0] histogram_read_count;


    logic [7:0] wr_addr, rd_addr;
    logic [15:0] rd_data;
    logic wr_en, rd_en;

    logic [39:0] energy;
    logic [39:0] energy_reg;
    logic energy_valid;

    logic [7:0] tx_data;
    logic tx_send, tx_busy, tx_half;


    logic [7:0] zcr;
    logic [7:0] zcr_reg;
    logic zcr_valid;
    logic sending_energy;
    logic [2:0] energy_index;

    typedef enum logic [2:0] {
        COLLECT,
        WAIT_ENERGY,
        READ_REQ,
        READ_WAIT,
        START_TX,
        WAIT_TX_BUSY,
        WAIT_TX_DONE
    } state_t;

    state_t state;

    assign wr_en = (state == COLLECT) && sample_valid;
    assign rd_en = (state == READ_REQ);




exact_histogram histogram (
    .clk(clk),
    .reset_n(cpu_resetn),

    .sample_in(sample),
    .sample_valid(wr_en),

    .read_index(histogram_read_index),
    .read_value(histogram_read_value),
    .read_count(histogram_read_count),

    .unique_count(histogram_unique_count),
    .hist_done(histogram_done),
    .ready(histogram_ready)
);

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
            wr_addr <= 0;
            rd_addr <= 0;
            tx_data <= 0;
            tx_send <= 0;
            tx_half <= 0;
            energy_reg <= 0;
            energy_index <= 0;
            sending_energy <= 0;
            zcr_reg <= 0;
        end
        else begin
            tx_send <= 0;

            case (state)

                
        COLLECT: begin
            if (sample_valid) begin
                if (wr_addr == 8'd255) begin
                    state <= WAIT_ENERGY;
                end
                else
                    wr_addr <= wr_addr + 1'b1;
            end
        end

        WAIT_ENERGY: begin
            if (energy_valid && zcr_valid) begin
                energy_reg <= energy;
                zcr_reg <= zcr;
                rd_addr <= 0;
                tx_half <= 0;
                sending_energy <= 0;
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

                        if (!sending_energy) begin
                            tx_data <= tx_half ?
                                rd_data[15:8] : rd_data[7:0];
                        end
                        else begin
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

                        if (sending_energy) begin
                            if (energy_index == 3'd5) begin
                                // Finished entire response
                                wr_addr <= 0;
                                rd_addr <= 0;
                                energy_index <= 0;
                                sending_energy <= 0;
                                state <= COLLECT;
                            end
                            else begin
                                energy_index <= energy_index + 1'b1;
                                state <= START_TX;
                            end
                        end

                        else if (!tx_half) begin
                            // Transmit high audio byte next
                            tx_half <= 1;
                            state <= START_TX;
                        end

                        else if (rd_addr == 8'd255) begin
                            // All audio sent; now send energy
                            sending_energy <= 1;
                            energy_index <= 0;
                            state <= START_TX;
                        end

                        else begin
                            rd_addr <= rd_addr + 1'b1;
                            tx_half <= 0;
                            state <= READ_REQ;
                        end
                    end
                end

                default: state <= COLLECT;

            endcase
        end
    end

endmodule
