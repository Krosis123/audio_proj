module audio_buffer(
    input logic clk,
    input logic wr_en,
    input logic [7:0] wr_addr,
    input logic[15:0] wr_data,
    input logic rd_en,
    input logic [7:0] rd_addr,
    output logic [15:0] rd_data
);

    logic [15:0] memory [0:255];

    always_ff @(posedge clk) begin
        if (wr_en)
            memory[wr_addr] <= wr_data;
        if (rd_en)
            rd_data <= memory[rd_addr];
    end

endmodule