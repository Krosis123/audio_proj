
module uart_tx #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 921600
)(
    input  logic       clk,
    input  logic       reset_n,
    input  logic       send,
    input  logic [7:0] data,
    output logic       tx,
    output logic       busy
);

    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam integer TIMER_WIDTH = $clog2(CLKS_PER_BIT);

    localparam logic [TIMER_WIDTH-1:0] LAST_TICK = TIMER_WIDTH'(CLKS_PER_BIT - 1);

    typedef enum logic [1:0] {
        IDLE, START_BIT, DATA_BITS, STOP_BIT
    } state_t;

    state_t state;

    logic [TIMER_WIDTH-1:0] timer;
    logic [2:0] bit_index;
    logic [7:0] data_reg;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= IDLE;
            tx        <= 1'b1;
            busy      <= 1'b0;
            timer     <= 0;
            bit_index <= 0;
            data_reg  <= 0;
        end
        else begin
            case (state)

                IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;

                    if (send) begin
                        data_reg <= data;
                        timer    <= 0;
                        busy     <= 1'b1;
                        tx       <= 1'b0;
                        state    <= START_BIT;
                    end
                end

                START_BIT: begin
                    if (timer == LAST_TICK) begin
                        timer     <= 0;
                        bit_index <= 0;
                        tx        <= data_reg[0];
                        state     <= DATA_BITS;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                DATA_BITS: begin
                    if (timer == LAST_TICK) begin
                        timer <= 0;

                        if (bit_index == 7) begin
                            tx    <= 1'b1;
                            state <= STOP_BIT;
                        end
                        else begin
                            bit_index <= bit_index + 1'b1;
                            tx <= data_reg[bit_index + 1'b1];
                        end
                    end
                    else
                        timer <= timer + 1'b1;
                end

                STOP_BIT: begin
                    if (timer == LAST_TICK) begin
                        timer <= 0;
                        busy  <= 1'b0;
                        state <= IDLE;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
