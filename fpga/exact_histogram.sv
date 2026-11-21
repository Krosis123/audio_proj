
module exact_histogram (
    input  logic clk,
    input  logic reset_n,

    input  logic [15:0] sample_in,
    input  logic sample_valid,

    // Read an entry from the histogram
    input  logic [7:0] read_index,
    output logic [15:0] read_value,
    output logic [8:0] read_count,

    // Information about the histogram
    output logic [8:0] unique_count,
    output logic hist_done,
    output logic ready
);

    // Up to 256 unique sample values
    logic [15:0] values [0:255];

    // Frequency of each value
    logic [8:0] counts [0:255];

    logic [7:0] sample_count;
    logic [7:0] search_index;
    logic [15:0] target_sample;

    typedef enum logic [1:0] {
        IDLE,
        SEARCH,
        COMMIT
    } state_t;

    state_t state;

    // External read interface
    assign read_value = values[read_index];
    assign read_count = counts[read_index];

    assign ready = (state == IDLE);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;

            sample_count <= 0;
            search_index <= 0;
            target_sample <= 0;

            unique_count <= 0;
            hist_done <= 0;
        end
        else begin
            case (state)

                IDLE: begin
                    if (sample_valid) begin

                        if (sample_count == 0) begin
                            // Start a new block
                            values[0] <= sample_in;
                            counts[0] <= 9'd1;

                            unique_count <= 9'd1;
                            sample_count <= 8'd1;
                            hist_done <= 0;
                        end
                        else begin
                            // Search existing entries
                            target_sample <= sample_in;
                            search_index <= 0;
                            state <= SEARCH;
                        end
                    end
                end

                SEARCH: begin

                    if (values[search_index] ==
                        target_sample) begin

                        // Existing value: increase count
                        counts[search_index] <=
                            counts[search_index] + 9'd1;

                        state <= COMMIT;
                    end

                    else if (
                        {1'b0, search_index} + 9'd1
                        == unique_count
                    ) begin

                        // No match: create a new entry
                        values[unique_count[7:0]]
                            <= target_sample;

                        counts[unique_count[7:0]]
                            <= 9'd1;

                        unique_count <= unique_count + 9'd1;

                        state <= COMMIT;
                    end

                    else begin
                        search_index <= search_index + 1'b1;
                    end
                end

                COMMIT: begin
                    if (sample_count == 8'd255) begin
                        // 256th sample completed
                        sample_count <= 0;
                        hist_done <= 1;
                    end
                    else begin
                        sample_count <= sample_count + 1'b1;
                    end

                    state <= IDLE;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
