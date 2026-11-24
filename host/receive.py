
import serial
import struct
import random
import math
from collections import Counter

PORT = "COM5"
BAUD = 115200
BLOCK_SIZE = 256
SCALE = 1 << 16


def read_exact(fpga, length):
    data = bytearray()

    while len(data) < length:
        chunk = fpga.read(length - len(data))

        if not chunk:
            raise TimeoutError(
                f"Expected {length} bytes, "
                f"received {len(data)}"
            )

        data.extend(chunk)

    return bytes(data)


def calculate_entropy(histogram):
    return -sum(
        (count / BLOCK_SIZE)
        * math.log2(count / BLOCK_SIZE)
        for count in histogram.values()
    )


def calculate_entropy_fixed(histogram):
    return sum(
        round(
            -(count / BLOCK_SIZE)
            * math.log2(count / BLOCK_SIZE)
            * SCALE
        )
        for count in histogram.values()
    )


rng = random.Random(42)

test_blocks = {
    "Silence": [0] * 256,

    "Alternating": [1000, -1000] * 128,

    "All unique": list(range(-128, 128)),

    "Random": [
        rng.randint(-32768, 32767)
        for _ in range(256)
    ],
}


with serial.Serial(PORT, BAUD, timeout=5) as fpga:

    fpga.reset_input_buffer()

    for name, samples in test_blocks.items():

        print(f"\nTesting: {name}")

        # Python reference calculations
        expected_hist = Counter(samples)

        expected_energy = sum(
            x * x for x in samples
        )

        expected_zcr = sum(
            (samples[i] < 0) != (samples[i - 1] < 0)
            for i in range(1, BLOCK_SIZE)
        )

        expected_entropy = calculate_entropy(
            expected_hist
        )

        expected_fixed = calculate_entropy_fixed(
            expected_hist
        )

        # Send 256 signed 16-bit samples
        encoded = struct.pack("<256h", *samples)

        fpga.write(encoded)
        fpga.flush()

        # Fixed-length response header
        header = read_exact(fpga, 523)

        audio_bytes = header[:512]
        energy_bytes = header[512:517]
        zcr_byte = header[517]
        entropy_bytes = header[518:521]
        unique_bytes = header[521:523]

        # Decode audio
        recovered = struct.unpack(
            "<256h", audio_bytes
        )

        # Decode statistics
        fpga_energy = int.from_bytes(
            energy_bytes, "little"
        )

        fpga_entropy_fixed = int.from_bytes(
            entropy_bytes, "little"
        )

        fpga_entropy = (
            fpga_entropy_fixed / SCALE
        )

        unique_count = int.from_bytes(
            unique_bytes, "little"
        )

        assert 1 <= unique_count <= 256, (
            f"Invalid unique count: {unique_count}"
        )

        # Read the variable-length histogram
        histogram_bytes = read_exact(
            fpga, unique_count * 4
        )

        entries = list(
            struct.iter_unpack(
                "<hH", histogram_bytes
            )
        )

        fpga_hist = dict(entries)

        # Debug histogram before assertions
        print("\n--- HISTOGRAM DEBUG ---")
        print("Test:", name)
        print("Expected unique values:", len(expected_hist))
        print("FPGA unique_count:", unique_count)
        print("Received entries:", len(entries))
        print("Distinct received values:", len(fpga_hist))
        print("Sum of frequencies:", sum(c for _, c in entries))

        value_frequency = Counter(v for v, c in entries)

        duplicates = [
            (value, frequency)
            for value, frequency in value_frequency.items()
            if frequency > 1
        ]

        print("Duplicate values:", duplicates[:10])
        print("First 10 entries:", entries[:10])
        print("Last 10 entries:", entries[-10:])

        if name == "All unique":
            incorrect = [
                (i, value, count, samples[i])
                for i, (value, count) in enumerate(entries)
                if value != samples[i] or count != 1
            ]

            print("First incorrect entries:", incorrect[:10])

        print("-----------------------\n")

        # Verify original audio
        assert list(recovered) == samples, "Audio mismatch"

        # Verify energy
        assert fpga_energy == expected_energy, "Energy mismatch"

        # Verify ZCR
        assert zcr_byte == expected_zcr, "ZCR mismatch"

        # Verify histogram
        assert len(fpga_hist) == unique_count, (
            "Duplicate histogram values detected"
        )

        assert sum(fpga_hist.values()) == 256, (
            "Histogram frequency sum mismatch"
        )

        assert fpga_hist == expected_hist, (
            "Histogram mismatch"
        )

        # Verify entropy
        print(f"Python entropy: {expected_entropy:.6f}")
        print(f"FPGA entropy:   {fpga_entropy:.6f}")
        print(f"Unique values:  {unique_count}")

        assert fpga_entropy_fixed == expected_fixed, (
            f"Entropy mismatch: "
            f"FPGA={fpga_entropy_fixed}, "
            f"expected={expected_fixed}"
        )

        print("Audio:      PASS")
        print("Energy:     PASS")
        print("ZCR:        PASS")
        print("Histogram:  PASS")
        print("Entropy:    PASS")
