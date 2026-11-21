
module entropy_calc (
    input logic clk,
    input logic reset_n,

    input logic start,

    // Number of distinct values
    input logic [8:0] unique_count,

    // Histogram interface
    output logic [7:0] read_index,
    input logic [8:0] read_count,

    // Result in fixed-point Q16 scaling
    output logic [19:0] entropy_q16,
    output logic entropy_valid
);

    // 257-entry entropy ROM
    logic [15:0] entropy_rom [0:256];

    initial begin
        $readmemh("entropy_lut.mem", entropy_rom);
    end

    logic [15:0] term_q;
    logic [19:0] accumulator;
    logic [8:0] total_entries;

    typedef enum logic [1:0] {
        IDLE,
        READ_COUNT,
        LOOKUP,
        ACCUMULATE
    } state_t;

    state_t state;

    // Synchronous lookup
    always_ff @(posedge clk) begin
        if (state == LOOKUP)
            term_q <= entropy_rom[read_count];
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            read_index <= 0;
            accumulator <= 0;
            total_entries <= 0;
            entropy_q16 <= 0;
            entropy_valid <= 0;
        end
        else begin
            entropy_valid <= 0;

            case (state)

                IDLE: begin
                    if (start) begin
                        read_index <= 0;
                        accumulator <= 0;
                        total_entries <= unique_count;

                        if (unique_count == 0) begin
                            entropy_q16 <= 0;
                            entropy_valid <= 1;
                        end
                        else begin
                            state <= READ_COUNT;
                        end
                    end
                end

                READ_COUNT: begin
                    // Histogram read is synchronous.
                    // Give it one clock to update.
                    state <= LOOKUP;
                end

                LOOKUP: begin
                    // ROM captures the contribution.
                    state <= ACCUMULATE;
                end

                ACCUMULATE: begin
                    accumulator <= accumulator
                                 + {4'b0, term_q};

                    if (
                        {1'b0, read_index} + 9'd1
                        == total_entries
                    ) begin
                        // Include the final contribution
                        entropy_q16 <= accumulator
                                     + {4'b0, term_q};

                        entropy_valid <= 1;
                        state <= IDLE;
                    end
                    else begin
                        read_index <= read_index + 8'd1;
                        state <= READ_COUNT;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
