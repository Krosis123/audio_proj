
import serial
import struct

PORT = "COM6"
samples = [0, 1000, -1000, 32767, -32768, 12345]

with serial.Serial(PORT, 115200, timeout=2) as fpga:
    fpga.reset_input_buffer()

    for sample in samples:

        # Convert signed 16-bit sample into 2 bytes
        encoded = struct.pack("<h", sample)

        received = bytearray()

        for byte in encoded:
            fpga.write(bytes([byte]))
            response = fpga.read(1)
            if len(response) != 1:
                raise RuntimeError("UART timeout")
            received.extend(response)
        recovered = struct.unpack("<h", received)[0]
        print(f"Original: {sample:6d} | Recovered: {recovered:6d}")

        assert sample == recovered

print("All audio samples recovered correctly!")
