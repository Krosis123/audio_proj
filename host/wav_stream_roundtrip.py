"""Stream a WAV through FPGA affine scramble + FPGA inverse + audio statistics.

FPGA response, per 256 signed samples (little-endian):
  512 bytes FPGA-restored PCM (scramble then inverse in hardware)
    5 bytes energy (unsigned)
    1 byte  zero crossing count
    3 bytes Q16 Shannon entropy (unsigned)
    2 bytes number of distinct sample values, K (unsigned)

The exact histogram remains inside the FPGA for entropy calculation;
it is not transmitted to the host.

The last block is padded with zeros for the FPGA but padding is removed
when writing the reconstructed WAV. Verifies PCM, energy, ZCR, entropy, and
unique-value count against Python calculations for each block.
"""

import argparse
import csv
import hashlib
import math
import struct
import time
import wave
from collections import Counter
from pathlib import Path

import serial

BLOCK_SAMPLES = 256
HEADER_BYTES = 523
ENTROPY_SCALE = 1 << 16


def read_exact(port: serial.Serial, length: int) -> bytes:
    received = bytearray()
    while len(received) < length:
        piece = port.read(length - len(received))
        if not piece:
            raise TimeoutError(
                f"UART timeout: expected {length} bytes, received {len(received)}"
            )
        received.extend(piece)
    return bytes(received)


def entropy_q16_reference(frequencies: Counter) -> int:
    return sum(
        round(
            -(count / BLOCK_SAMPLES)
            * math.log2(count / BLOCK_SAMPLES)
            * ENTROPY_SCALE
        )
        for count in frequencies.values()
    )


def process_block(port: serial.Serial, samples: list[int], block_number: int):
    if len(samples) != BLOCK_SAMPLES:
        raise ValueError("FPGA accepts exactly 256 samples per block")

    expected_hist = Counter(samples)
    expected_energy = sum(s * s for s in samples)
    expected_zcr = sum(
        (samples[i] < 0) != (samples[i - 1] < 0)
        for i in range(1, BLOCK_SAMPLES)
    )
    expected_entropy_fixed = entropy_q16_reference(expected_hist)

    port.write(struct.pack("<256h", *samples))
    port.flush()

    header = read_exact(port, HEADER_BYTES)
    audio_out = header[:512]
    energy = int.from_bytes(header[512:517], "little")
    zcr = header[517]
    entropy_fixed = int.from_bytes(header[518:521], "little")
    unique_count = int.from_bytes(header[521:523], "little")

    if not 1 <= unique_count <= 256:
        raise AssertionError(
            f"Block {block_number}: invalid unique count {unique_count}"
        )

    # Histogram entries stay inside the FPGA. Validate the final
    # statistics against an exact-value Counter constructed in Python.
    checks = {
        "audio": audio_out == struct.pack("<256h", *samples),
        "energy": energy == expected_energy,
        "zcr": zcr == expected_zcr,
        "unique_count": unique_count == len(expected_hist),
        "entropy": entropy_fixed == expected_entropy_fixed,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise AssertionError(
            f"Block {block_number}: failed {', '.join(failed)}; "
            f"K={unique_count}/{len(expected_hist)}, "
            f"energy={energy}/{expected_energy}, "
            f"ZCR={zcr}/{expected_zcr}, "
            f"H_Q16={entropy_fixed}/{expected_entropy_fixed}"
        )

    return audio_out, energy, zcr, entropy_fixed / ENTROPY_SCALE, unique_count


def run(args):
    source = Path(args.input)
    destination = Path(args.output)
    report = Path(args.csv)

    if source.resolve() == destination.resolve():
        raise ValueError("Input and output WAV filenames must be different")

    with wave.open(str(source), "rb") as source_wav:
        channels = source_wav.getnchannels()
        sample_width = source_wav.getsampwidth()
        sample_rate = source_wav.getframerate()
        frame_total = source_wav.getnframes()

        if source_wav.getcomptype() != "NONE" or sample_width != 2:
            raise ValueError("Input must be uncompressed 16-bit PCM WAV")
        if channels not in (1, 2):
            raise ValueError("This script supports mono or stereo WAV only")

        frames_per_block = BLOCK_SAMPLES // channels
        full_block_total = (frame_total + frames_per_block - 1) // frames_per_block
        block_total = (min(full_block_total, args.max_blocks)
                       if args.max_blocks is not None else full_block_total)
        duration = frame_total / sample_rate

        print(
            f"Input: {source} | {duration:.2f}s | {sample_rate} Hz | "
            f"{channels} channel(s) | {block_total}/{full_block_total} FPGA blocks"
        )
        print(f"Serial: {args.port} @ {args.baud} baud")
        print(f"Output: {destination} | Report: {report}")

        source_digest = hashlib.sha256()
        recovered_digest = hashlib.sha256()
        started = time.monotonic()

        with (
            serial.Serial(args.port, args.baud, timeout=args.timeout) as port,
            wave.open(str(destination), "wb") as output_wav,
            report.open("w", newline="", encoding="utf-8") as report_file,
        ):
            port.reset_input_buffer()
            output_wav.setnchannels(channels)
            output_wav.setsampwidth(2)
            output_wav.setframerate(sample_rate)

            writer = csv.writer(report_file)
            writer.writerow(
                ["block", "first_frame", "frame_count", "valid_samples",
                 "unique_values", "entropy_bits_per_sample", "energy", "zcr"]
            )

            frame_index = 0
            for block in range(block_total):
                pcm_data = source_wav.readframes(frames_per_block)
                actual_samples = len(pcm_data) // 2
                actual_frames = actual_samples // channels
                samples = list(struct.unpack(f"<{actual_samples}h", pcm_data))
                padded_samples = samples + [0] * (BLOCK_SAMPLES - actual_samples)

                try:
                    result, energy, zcr, entropy, unique = process_block(
                        port, padded_samples, block
                    )
                except Exception as exc:
                    raise RuntimeError(
                        f"Failed on block {block + 1}/{block_total} "
                        f"(frame {frame_index}): {exc}"
                    ) from exc

                recovered_pcm = result[:len(pcm_data)]
                output_wav.writeframesraw(recovered_pcm)
                source_digest.update(pcm_data)
                recovered_digest.update(recovered_pcm)
                writer.writerow(
                    [block, frame_index, actual_frames, actual_samples,
                     unique, f"{entropy:.8f}", energy, zcr]
                )
                frame_index += actual_frames

                if (block + 1) % args.progress == 0 or block + 1 == block_total:
                    elapsed = time.monotonic() - started
                    print(
                        f"Blocks {block + 1}/{block_total} | "
                        f"{100 * (block + 1) / block_total:.1f}% | "
                        f"elapsed {elapsed:.1f}s | last H={entropy:.4f}"
                    )

    identical = source_digest.digest() == recovered_digest.digest()
    print(f"PCM SHA-256 input:     {source_digest.hexdigest()}")
    print(f"PCM SHA-256 recovered: {recovered_digest.hexdigest()}")
    print(f"Bit-exact PCM match:   {identical}")
    if not identical:
        raise AssertionError("Recovered audio samples differ from input")
    if args.max_blocks is not None and block_total < full_block_total:
        print("SUCCESS: tested WAV prefix recovered bit-exactly on the FPGA")
    else:
        print("SUCCESS: every FPGA block and the complete recovered PCM stream match")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="input.wav", help="Input 16-bit PCM WAV")
    parser.add_argument("--output", default="recovered.wav", help="Recovered WAV filename")
    parser.add_argument("--csv", default="audio_stats.csv", help="Per-block statistics CSV")
    parser.add_argument("--port", default="COM5", help="UART port (default: COM5)")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--progress", type=int, default=25, help="Print progress every N blocks")
    parser.add_argument("--max-blocks", type=int, default=None,
                        help="Process only the first N blocks for a quick test")
    args = parser.parse_args()
    if args.progress <= 0:
        parser.error("--progress must be positive")
    if args.max_blocks is not None and args.max_blocks <= 0:
        parser.error("--max-blocks must be positive")
    run(args)


if __name__ == "__main__":
    main()
