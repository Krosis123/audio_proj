module zcr_calc (
    input logic clk,
    input logic reset_n,

    input logic [15:0] sample_in,
    input logic sample_valid,
    output logic[7:0] zcr,
    output logic zcr_valid
);

logic [7:0] sample_count;
logic previous_sign;
logic crossing;
assign crossing = previous_sign ^ sample_in[15];

always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_count  <= 0;
            previous_sign <= 0;
            zcr           <= 0;
            zcr_valid     <= 0;
        end
        else begin
            zcr_valid <= 0;

            if (sample_valid) begin

                if (sample_count == 0) begin
                    zcr <= 0;
                    previous_sign <= sample_in[15];
                    sample_count <= 1;
                end
                else begin
                    zcr <= zcr + {7'b0, crossing};

                    previous_sign <= sample_in[15];

                    if (sample_count == 8'd255) begin
                        sample_count <= 0;
                        zcr_valid <= 1;
                    end
                    else begin
                        sample_count <= sample_count + 1'b1;
                    end
                end
            end
        end
    end

endmodule