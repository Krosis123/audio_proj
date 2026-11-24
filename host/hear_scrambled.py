"""Create a listenable WAV of the exact affine scrambling used by the FPGA.

This is a host-side reproduction of the already-verified FPGA permutation,
not an FPGA capture or cryptographic encryption. Optionally cross-check each
block's feature values against the FPGA's audio_stats.csv report.

The final incomplete 256-sample block is zero-padded, preserving the complete
scrambled block (at most 255 extra PCM samples / channels in duration).
"""

import argparse
import csv
import hashlib
import math
import struct
import wave
from collections import Counter
from pathlib import Path

BLOCK_SAMPLES = 256
ENTROPY_SCALE = 1 << 16


def features(samples: list[int]) -> tuple[int, int, int, int]:
    freq = Counter(samples)
    energy = sum(value * value for value in samples)
    zcr = sum((samples[i] < 0) != (samples[i - 1] < 0)
              for i in range(1, BLOCK_SAMPLES))
    entropy_fixed = sum(round(-(count / BLOCK_SAMPLES)
                              * math.log2(count / BLOCK_SAMPLES)
                              * ENTROPY_SCALE)
                        for count in freq.values())
    return energy, zcr, entropy_fixed, len(freq)


def check_stats(row, block_no, actual_samples, energy, zcr, entropy_fixed, unique, a, b):
    expected = {
        'block': block_no,
        'valid_samples': actual_samples,
        'energy': energy,
        'zcr': zcr,
        'unique_values': unique,
    }
    for field, want in expected.items():
        if field in row and int(row[field]) != want:
            raise ValueError(
                f"Block {block_no}: audio_stats.csv {field}={row[field]} "
                f"does not match WAV value {want}. Use the CSV from this WAV."
            )
    if 'entropy_bits_per_sample' in row:
        recorded_q16 = round(float(row['entropy_bits_per_sample']) * ENTROPY_SCALE)
        if recorded_q16 != entropy_fixed:
            raise ValueError(
                f"Block {block_no}: CSV entropy Q16={recorded_q16} "
                f"but current input gives {entropy_fixed}"
            )
    for field, want in [('perm_a', a), ('perm_b', b)]:
        if field in row and int(row[field]) != want:
            raise ValueError(f"Block {block_no}: CSV {field} mismatch")


def run(args):
    source = Path(args.input)
    output = Path(args.output)
    if source.resolve() == output.resolve():
        raise ValueError('Input and output WAV must have different names')
    rows = None
    if args.stats:
        with Path(args.stats).open('r', newline='', encoding='utf-8') as f:
            rows = list(csv.DictReader(f))

    original_hash = hashlib.sha256()
    recovered_hash = hashlib.sha256()
    block_total = 0
    with wave.open(str(source), 'rb') as input_wav:
        if input_wav.getcomptype() != 'NONE' or input_wav.getsampwidth() != 2:
            raise ValueError('Input must be uncompressed 16-bit PCM WAV')
        channels = input_wav.getnchannels()
        if channels not in (1, 2) or 256 % channels:
            raise ValueError('Only mono and stereo WAV files are supported')
        rate = input_wav.getframerate()
        frames_per_block = 256 // channels
        blocks_expected = (input_wav.getnframes() + frames_per_block - 1) // frames_per_block
        if rows is not None and len(rows) != blocks_expected:
            raise ValueError(
                f'CSV has {len(rows)} blocks, input WAV needs {blocks_expected}. '
                'Use the complete audio_stats.csv from the same WAV.'
            )

        with wave.open(str(output), 'wb') as scrambled_wav:
            scrambled_wav.setnchannels(channels)
            scrambled_wav.setsampwidth(2)
            scrambled_wav.setframerate(rate)
            for block_no in range(blocks_expected):
                pcm = input_wav.readframes(frames_per_block)
                actual = len(pcm) // 2
                samples = list(struct.unpack(f'<{actual}h', pcm))
                samples.extend([0] * (BLOCK_SAMPLES - actual))
                energy, zcr, entropy_fixed, unique = features(samples)

                # Exact definitions used by the verified top_affine/top_roundtrip.
                a = ((zcr ^ (entropy_fixed & 0xFF)) | 1) & 0xFF
                b = ((energy & 0xFF) ^ ((entropy_fixed >> 8) & 0xFF)) & 0xFF
                if rows is not None:
                    check_stats(rows[block_no], block_no, actual, energy, zcr,
                                entropy_fixed, unique, a, b)

                scrambled = [samples[(a * i + b) & 0xFF]
                             for i in range(BLOCK_SAMPLES)]
                scrambled_wav.writeframesraw(struct.pack('<256h', *scrambled))

                # Verify that the inverse really reproduces all 256 samples.
                restored = [0] * BLOCK_SAMPLES
                for i, value in enumerate(scrambled):
                    restored[(a * i + b) & 0xFF] = value
                assert restored == samples, f'Inverse failed in block {block_no}'

                original_hash.update(pcm)
                recovered_hash.update(struct.pack(f'<{actual}h', *restored[:actual]))
                block_total += 1

    print(f'Scrambled preview: {output}')
    print(f'Processed blocks: {block_total}')
    print(f'Feature source: {"FPGA CSV checked against WAV" if rows is not None else "Python recomputation of FPGA equations"}')
    print('Input SHA-256:    ', original_hash.hexdigest())
    print('Inverse SHA-256:  ', recovered_hash.hexdigest())
    print('Inverse bit-exact:', original_hash.digest() == recovered_hash.digest())
    print('Play the scrambled WAV in a normal audio player.')
    print('Note: this is affine scrambling, NOT AES-encrypted audio.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', required=True, help='Original uncompressed 16-bit PCM WAV')
    p.add_argument('--output', default='scrambled.wav', help='Scrambled preview WAV')
    p.add_argument('--stats', help='Optional FPGA-generated audio_stats.csv for cross-check')
    run(p.parse_args())


if __name__ == '__main__':
    main()
