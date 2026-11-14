
import serial
import struct
import random
# MEOWWWW
PORT = "COM6"
BLOCK_SIZE = 256

rng = random.Random(67)
samples = [0, 1000, -1000, 32767, -32768]
while len(samples) < BLOCK_SIZE:
    samples.append(rng.randint(-32768, 32767))

encoded = struct.pack("<256h", *samples)
expected_energy = sum(x * x for x in samples)

expected_zcr = sum(
    (samples[i] < 0) != (samples[i-1] < 0)
    for i in range(1, BLOCK_SIZE)
)

with serial.Serial(PORT, 115200, timeout=5) as fpga:

    fpga.reset_input_buffer()
    fpga.write(encoded)

    received = fpga.read(518)

    if len(received) != 518:
        raise RuntimeError(
            f"Expected 518, got {len(received)}"
        )

    audio_bytes = received[:512]
    energy_bytes = received[512:517]
    zcr_byte = received[517]

    recovered = struct.unpack("<256h", audio_bytes)

    fpga_energy = int.from_bytes(
        energy_bytes, byteorder="little"
    )

    assert list(recovered) == samples
    assert fpga_energy == expected_energy
    assert zcr_byte == expected_zcr

    print("Audio samples: Meow")
    print("Energy (Python):", expected_energy)
    print("Energy (FPGA):  ", fpga_energy)
    print("ZCR (Python):   ", expected_zcr)
    print("ZCR (FPGA):     ", zcr_byte)
    print("pass")
