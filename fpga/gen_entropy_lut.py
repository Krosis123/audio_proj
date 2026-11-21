
import math

SCALE = 1 << 16
BLOCK_SIZE = 256

with open("entropy_lut.mem", "w") as f:
    for count in range(BLOCK_SIZE + 1):

        if count == 0:
            contribution = 0
        else:
            p = count / BLOCK_SIZE
            contribution = -p * math.log2(p)

        fixed = round(contribution * SCALE)

        # Store as a 16-bit hexadecimal number
        f.write(f"{fixed:04X}\n")

print("Generated 257 entropy lookup values.")
