`timescale 1ns/1ps
// aes128_tb.sv -- simulation-only testbench; keep in fpga/tests/.
module aes128_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk; // 100 MHz

    logic reset_n = 1'b0;
    logic start = 1'b0;
    logic [127:0] plaintext = 128'd0;
    logic [127:0] key = 128'd0;
    wire [127:0] ciphertext;
    wire busy, done;

    aes128_core dut (
        .clk(clk), .reset_n(reset_n), .start(start),
        .plaintext(plaintext), .key(key),
        .ciphertext(ciphertext), .busy(busy), .done(done)
    );

    task automatic run_vector(
        input logic [127:0] test_key,
        input logic [127:0] test_pt,
        input logic [127:0] expected
    );
        logic finished;
        begin
            @(negedge clk);
            key = test_key;
            plaintext = test_pt;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            finished = 1'b0;
            for (integer n = 0; n < 100 && !finished; n++) begin
                @(negedge clk);
                if (done) begin
                    if (ciphertext !== expected) begin
                        $display("FAIL expected %032h got %032h", expected, ciphertext);
                        $fatal(1, "AES-128 KAT mismatch");
                    end
                    $display("PASS key=%032h plaintext=%032h ciphertext=%032h", test_key, test_pt, ciphertext);
                    finished = 1'b1;
                end
            end
            if (!finished) $fatal(1, "AES-128 timed out");
        end
    endtask

    initial begin
    $dumpvars(0, aes128_tb);

    repeat (4) @(negedge clk);
    reset_n = 1'b1;

        // NIST FIPS 197, Appendix C.1
        run_vector(
            128'h000102030405060708090a0b0c0d0e0f,
            128'h00112233445566778899aabbccddeeff,
            128'h69c4e0d86a7b0430d8cdb78070b4c55a
        );

        // Independent zero-key / zero-block AES-128 known-answer test
        run_vector(
            128'h00000000000000000000000000000000,
            128'h00000000000000000000000000000000,
            128'h66e94bd4ef8a2c3b884cfa59ca342b2e
        );

        // SP 800-38A AES-128 ECB single-block known-answer vector
        run_vector(
            128'h2b7e151628aed2a6abf7158809cf4f3c,
            128'h6bc1bee22e409f96e93d7e117393172a,
            128'h3ad77bb40d7a3660a89ecaf32466ef97
        );

        $display("ALL AES-128 TEST VECTORS PASSED");
        $finish;
    end
endmodule
