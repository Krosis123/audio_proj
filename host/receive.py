
import serial
import struct
import random
from collections import Counter

PORT = "COM6"
BAUD = 115200
BLOCK_SIZE = 256


def read_exact(fpga, length):
    data = bytearray()

    while len(data) < length:
        chunk = fpga.read(length - len(data))

        if not chunk:
            raise TimeoutError(
                f"Expected {length} bytes, got {len(data)}"
            )

        data.extend(chunk)

    return bytes(data)


rng = random.Random(42)

test_blocks = {
    "Silence": [0] * 256,
    "Alternating": [1000, -1000] * 128,
    "All unique": list(range(-128, 128)),
    "Random": [
        rng.randint(-32768, 32767)
        for _ in range(BLOCK_SIZE)
    ],
}

with serial.Serial(PORT, BAUD, timeout=5) as fpga:

    fpga.reset_input_buffer()

    for name, samples in test_blocks.items():

        encoded = struct.pack("<256h", *samples)

        expected_energy = sum(x * x for x in samples)

        expected_zcr = sum(
            (samples[i] < 0) != (samples[i - 1] < 0)
            for i in range(1, BLOCK_SIZE)
        )

        expected_hist = Counter(samples)

        # Send 256 samples to the FPGA
        fpga.write(encoded)

        # Read audio + energy + ZCR + unique count
        header = read_exact(fpga, 520)

        audio_bytes = header[:512]
        energy_bytes = header[512:517]
        zcr_byte = header[517]
        unique_bytes = header[518:520]

        # Decode returned data
        recovered = struct.unpack("<256h", audio_bytes)

        fpga_energy = int.from_bytes(
            energy_bytes, "little"
        )

        unique_count = int.from_bytes(
            unique_bytes, "little"
        )

        assert 1 <= unique_count <= 256

        # Each entry is 4 bytes
        histogram_bytes = read_exact(
            fpga, unique_count * 4
        )

        entries = list(
            struct.iter_unpack("<hH", histogram_bytes)
        )

        fpga_hist = dict(entries)

        # Verify all results
        assert list(recovered) == samples
        assert fpga_energy == expected_energy
        assert zcr_byte == expected_zcr

        assert len(fpga_hist) == unique_count
        assert sum(fpga_hist.values()) == 256
        assert fpga_hist == expected_hist

        print(f"\n{name}")
        print("  Energy:       MATCH")
        print("  ZCR:          MATCH")
        print("  Histogram:    MATCH")
        print("  Unique values:", unique_count)

print("\nAll FPGA tests passed!")
