
module exact_histogram (
    input  logic clk,
    input  logic reset_n,

    input  logic [15:0] sample_in,
    input  logic sample_valid,

    input  logic [7:0] read_index,
    output logic [15:0] read_value,
    output logic [8:0] read_count,

    output logic [8:0] unique_count,
    output logic hist_done,
    output logic ready
);

    logic [15:0] values [0:255];
    logic [8:0] counts [0:255];

    logic [7:0] sample_count;
    logic [7:0] search_index;
    logic [15:0] target_sample;

    logic [7:0] mem_addr;
    logic [15:0] mem_value_q;
    logic [8:0] mem_count_q;

    logic mem_we;
    logic [7:0] mem_wr_addr;
    logic [15:0] mem_wr_value;
    logic [8:0] mem_wr_count;

    typedef enum logic [1:0] {
        IDLE,
        SEARCH_READ,
        SEARCH_CHECK,
        COMMIT
    } state_t;

    state_t state;

    logic match_found;
    logic last_entry;

    assign ready = (state == IDLE);

    assign match_found =
        (mem_value_q == target_sample);

    assign last_entry =
        ({1'b0, search_index} + 9'd1 == unique_count);

    // One shared synchronous read port
    assign mem_addr =
        (state == SEARCH_READ ||
         state == SEARCH_CHECK)
        ? search_index : read_index;

    assign read_value = mem_value_q;
    assign read_count = mem_count_q;

    // Generate memory write controls
    always_comb begin
        mem_we = 1'b0;
        mem_wr_addr = 0;
        mem_wr_value = 0;
        mem_wr_count = 0;

        if (state == IDLE &&
            sample_valid &&
            sample_count == 0) begin

            mem_we = 1'b1;
            mem_wr_addr = 0;
            mem_wr_value = sample_in;
            mem_wr_count = 9'd1;
        end
        else if (state == SEARCH_CHECK) begin

            if (match_found) begin
                mem_we = 1'b1;
                mem_wr_addr = search_index;
                mem_wr_value = target_sample;
                mem_wr_count = mem_count_q + 9'd1;
            end
            else if (last_entry) begin
                mem_we = 1'b1;
                mem_wr_addr = unique_count[7:0];
                mem_wr_value = target_sample;
                mem_wr_count = 9'd1;
            end
        end
    end

    // Synchronous memory access
    always_ff @(posedge clk) begin
        mem_value_q <= values[mem_addr];
        mem_count_q <= counts[mem_addr];

        if (mem_we) begin
            values[mem_wr_addr] <= mem_wr_value;
            counts[mem_wr_addr] <= mem_wr_count;
        end
    end

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
                            unique_count <= 9'd1;
                            sample_count <= 8'd1;
                            hist_done <= 0;
                        end
                        else begin
                            target_sample <= sample_in;
                            search_index <= 0;
                            state <= SEARCH_READ;
                        end
                    end
                end

                SEARCH_READ: begin
                    state <= SEARCH_CHECK;
                end

                SEARCH_CHECK: begin
                    if (match_found) begin
                        state <= COMMIT;
                    end
                    else if (last_entry) begin
                        unique_count <= unique_count + 9'd1;
                        state <= COMMIT;
                    end
                    else begin
                        search_index <= search_index + 1'b1;
                        state <= SEARCH_READ;
                    end
                end

                COMMIT: begin
                    if (sample_count == 8'd255) begin
                        sample_count <= 0;
                        hist_done <= 1'b1;
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
