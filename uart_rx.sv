
module uart_rx #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 115_200
)(
    input  logic       clk,
    input  logic       reset_n,
    input  logic       rx,

    output logic [7:0] data,
    output logic       data_valid,
    output logic       frame_error
);

    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam integer HALF_BIT = CLKS_PER_BIT / 2;
    localparam integer TIMER_WIDTH = $clog2(CLKS_PER_BIT);
    localparam logic [TIMER_WIDTH-1:0] LAST_TICK = TIMER_WIDTH'(CLKS_PER_BIT - 1);
    localparam logic [TIMER_WIDTH-1:0] HALF_TICK = TIMER_WIDTH'(HALF_BIT - 1);
    logic [TIMER_WIDTH-1:0] timer;

    typedef enum logic [1:0] {
        IDLE, START_BIT, DATA_BITS, STOP_BIT
    } state_t;

    state_t state;
    logic [2:0] bit_index;
    logic [7:0] shift_reg;

    logic rx_meta, rx_sync;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= IDLE;
            timer       <= 0;
            bit_index   <= 0;
            shift_reg   <= 0;
            data        <= 0;
            data_valid  <= 0;
            frame_error <= 0;
        end
        else begin
            data_valid  <= 0;
            frame_error <= 0;

            case (state)

                IDLE: begin
                    timer <= 0;

                    if (!rx_sync) begin
                        state <= START_BIT;
                    end
                end

                START_BIT: begin
                    if (timer == HALF_TICK) begin
                        timer <= 0;

                        if (!rx_sync) begin
                            bit_index <= 0;
                            state <= DATA_BITS;
                        end
                        else begin
                            state <= IDLE;
                        end
                    end
                    else
                        timer <= timer + 1'b1;
                end

                DATA_BITS: begin
                    if (timer == LAST_TICK) begin
                        timer <= 0;

                        shift_reg[bit_index] <= rx_sync;

                        if (bit_index == 7)
                            state <= STOP_BIT;
                        else
                            bit_index <= bit_index + 1'b1;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                STOP_BIT: begin
                    if (timer == LAST_TICK) begin
                        timer <= 0;

                        if (rx_sync) begin
                            data <= shift_reg;
                            data_valid <= 1'b1;
                        end
                        else begin
                            frame_error <= 1'b1;
                        end

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
