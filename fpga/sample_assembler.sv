
module sample_assembler (
    input  logic clk,
    input  logic reset_n,
    input  logic [7:0] byte_data,
    input  logic byte_valid,
    output logic signed [15:0] sample,
    output logic sample_valid
);
    logic [7:0] low_byte;
    logic expecting_high;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            low_byte       <= 0;
            expecting_high <= 0;
            sample         <= 0;
            sample_valid   <= 0;
        end
        else begin
            sample_valid <= 0;
            if (byte_valid) begin

                if (!expecting_high) begin
                    low_byte <= byte_data;
                    expecting_high <= 1;
                end
                else begin
                    sample <= {byte_data, low_byte};
                    sample_valid <= 1;
                    expecting_high <= 0;
                end
            end
        end
    end
endmodule
