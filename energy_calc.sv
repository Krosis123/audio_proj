
module energy_calc (
    input  logic clk,
    input  logic reset_n,

    input  logic signed [15:0] sample_in,
    input  logic sample_valid,

    output logic [39:0] energy,
    output logic energy_valid
);

    logic [7:0] sample_count;
    logic signed [31:0] square;
    assign square = sample_in * sample_in;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_count <= 0;
            energy <= 0;
            energy_valid <= 0;
        end
        else begin
            energy_valid <= 0;

            if (sample_valid) begin
                if (sample_count == 0)
                    energy <= {8'b0, square};
                else
                    energy <= energy + {8'b0, square};
                if (sample_count == 8'd255) begin
                    sample_count <= 0;
                    energy_valid <= 1;
                end
                else begin
                    sample_count <= sample_count + 1'b1;
                end
            end
        end
    end

endmodule
