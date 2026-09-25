"""
=============================================================================
conv.py - Parameterized Golden Model & Hardware Test Vector Generator
=============================================================================
QUICK CONFIGURATION - Edit the values in CONFIGURATION BLOCK below, then run:

    python conv.py

Or override any parameter from the command line:

    python conv.py --mode 3 --img_size 64 --kernel_size 5 --num_cases 20
    python conv.py --mode 2 --img_width 64 --img_height 32 --kernel_size 3
    python conv.py --mode all --img_size 32 --kernel_size 3 --num_cases 10

Supported Modes:
    Mode 1 - Centrosymmetric   : IS_SYMMETRIC=1, NUM_KERNELS=1
              Kernel satisfies W[r,c] == W[K-1-r, K-1-c].
              Uses (NUM_TAPS+1)//2 unique DSPs (e.g. 5 DSPs for 3x3).

    Mode 2 - Asymmetric Dual-Patch : IS_SYMMETRIC=0, NUM_KERNELS=1
              One kernel applied to 2 patches simultaneously.
              2 output pixels per clock cycle.

    Mode 3 - Asymmetric Dual-Kernel : IS_SYMMETRIC=0, NUM_KERNELS=2
              Two independent kernels applied to the same patch.
              2 kernel outputs per clock cycle.

Output files (.mem):
    all_images_m{mode}.mem   - Unsigned 8-bit pixels   (1 byte/line, hex)
    all_weights_m{mode}.mem  - Signed 8-bit weights    (1 byte/line, hex 2's complement)
    all_expected_m{mode}.mem - Signed 16-bit outputs   (2 bytes/line, hex)

    Also writes generic all_images.mem / all_weights.mem / all_expected.mem
    (these are the active files read by the testbench when no mode tag is found).
=============================================================================
"""

# =============================================================================
# +==========================================================+
# |           CONFIGURATION BLOCK - Edit Here               |
# +==========================================================+
# =============================================================================

DEFAULT_CFG = {
    # Operating mode: 1 (Symmetric), 2 (Dual-Patch), 3 (Dual-Kernel), or "all"
    "mode"       : 2,

    # Image dimensions (pixels)
    "img_width"  : 32,
    "img_height" : 32,

    # Kernel (filter) size - square. 1, 3, 5, 7, or 9.
    "kernel_size":3,

    # Number of kernels (independent filters to apply simultaneously):
    #   Mode 1  -> always 1  (forced; symmetric hardware only has 1 kernel)
    #   Mode 2  -> always 1  (forced; dual-patch uses one kernel on 2 patches)
    #   Mode 3  -> 2 or more, MUST be an even number >= 2
    #             (hardware processes 2 kernels per cycle, iterates for >2)
    "num_kernels": 1,

    # Number of random test cases per mode
    "num_cases"  : 10,

    # Output directory for .mem files  (use forward slashes or raw strings)
    "output_dir" : "E:",

    # Random seed for reproducibility
    "seed"       : 42,
}

# =============================================================================
# Implementation - No need to edit below this line
# =============================================================================

import os
import sys
import argparse
import numpy as np


# ---------------------------------------------------------------------------
# Truncation rule - must match hardware get_trunc_bits() in tb_convolver_top.sv
# ---------------------------------------------------------------------------
def get_trunc_bits(kernel_size: int) -> int:
    if kernel_size >= 7:
        return 3
    elif kernel_size >= 3:
        return 2
    else:
        return 0


# ---------------------------------------------------------------------------
# Core 2-D convolution matching FPGA datapath exactly
# ---------------------------------------------------------------------------
def hw_conv2d(image: np.ndarray, kernel: np.ndarray, stride: int = 1) -> np.ndarray:
    """
    2D convolution matching the FPGA hardware pipeline:
      - image  : uint8 (H x W)
      - kernel : int8  (Kh x Kw)
      - Accumulate in int32
      - Arithmetic right-shift by TRUNC_BITS
      - ReLU + saturate to [0, 32767]  ->  int16
    """
    assert image.dtype  == np.uint8,  "image must be uint8"
    assert kernel.dtype == np.int8,   "kernel must be int8"

    kh, kw        = kernel.shape
    ih, iw        = image.shape
    trunc         = get_trunc_bits(kh)

    out_h = (ih - kh) // stride + 1
    out_w = (iw - kw) // stride + 1

    out = np.zeros((out_h, out_w), dtype=np.int32)
    for r in range(out_h):
        for c in range(out_w):
            patch  = image[r*stride:r*stride+kh, c*stride:c*stride+kw].astype(np.int32)
            out[r, c] = np.sum(patch * kernel.astype(np.int32))

    # Arithmetic right-shift (matches Verilog >>>/TRUNC_BITS)
    if trunc > 0:
        # Python '>>' on int32 is arithmetic
        out = out.astype(np.int32) >> trunc

    # ReLU + saturate to int16 positive range [0, 32767]
    out = np.clip(out, 0, 32767).astype(np.int16)
    return out


# ---------------------------------------------------------------------------
# Kernel generators
# ---------------------------------------------------------------------------
def make_symmetric_kernel(rng: np.random.Generator, kernel_size: int) -> np.ndarray:
    """
    Centrosymmetric kernel: tap[i] == tap[N-1-i] for all i.
    E.g. 3x3 has 5 unique weights; 5x5 has 13 unique weights.
    """
    n = kernel_size * kernel_size
    n_unique = (n + 1) // 2
    unique = rng.integers(-128, 128, size=n_unique, dtype=np.int32).astype(np.int8)

    flat = np.zeros(n, dtype=np.int8)
    for i in range(n_unique):
        flat[i]       = unique[i]
        flat[n-1-i]   = unique[i]        # mirror
    return flat.reshape(kernel_size, kernel_size)


def make_asymmetric_kernels(rng: np.random.Generator,
                            num_kernels: int, kernel_size: int) -> list:
    """Returns a list of `num_kernels` independent random int8 kernels."""
    return [rng.integers(-128, 128, size=(kernel_size, kernel_size),
                         dtype=np.int32).astype(np.int8)
            for _ in range(num_kernels)]


# ---------------------------------------------------------------------------
# .mem file writer (appends to open file objects)
# ---------------------------------------------------------------------------
def write_vectors(f_img, f_wt, f_exp,
                  image: np.ndarray, kernels: list):
    """
    Append one test case to the three open .mem file handles.
    """
    # Image: 1 byte per pixel, unsigned hex
    for px in image.flatten():
        f_img.write(f"{int(px) & 0xFF:02x}\n")

    # Weights: 1 byte per weight, signed 2's complement hex
    for k in kernels:
        for w in k.flatten():
            f_wt.write(f"{int(w) & 0xFF:02x}\n")

    # Expected outputs: 2 bytes per output pixel, hex
    for k in kernels:
        result = hw_conv2d(image, k, stride=1)
        for val in result.flatten():
            f_exp.write(f"{int(val) & 0xFFFF:04x}\n")


# ---------------------------------------------------------------------------
# Main generation routine
# ---------------------------------------------------------------------------
def generate(mode: int,
             img_width: int, img_height: int,
             kernel_size: int,
             num_kernels: int,
             num_cases: int,
             output_dir: str,
             seed: int):

    is_symmetric = (mode == 1)

    # Enforce hardware constraints per mode
    if mode == 1:
        if num_kernels != 1:
            print(f"[WARNING] Mode 1 (Centrosymmetric) only supports 1 kernel. "
                  f"Overriding num_kernels={num_kernels} -> 1")
        num_kernels = 1
    elif mode == 2:
        if num_kernels != 1:
            print(f"[WARNING] Mode 2 (Dual-Patch) only supports 1 kernel. "
                  f"Overriding num_kernels={num_kernels} -> 1")
        num_kernels = 1
    else:  # mode == 3
        if num_kernels < 2:
            print(f"[WARNING] Mode 3 requires num_kernels >= 2. "
                  f"Overriding num_kernels={num_kernels} -> 2")
            num_kernels = 2
        if num_kernels % 2 != 0:
            print(f"[WARNING] Mode 3 requires an even number of kernels (hardware processes 2/cycle). "
                  f"Rounding up num_kernels={num_kernels} -> {num_kernels + 1}")
            num_kernels += 1

    # Derived dimensions
    out_w = img_width  - kernel_size + 1
    out_h = img_height - kernel_size + 1
    out_pixels_per_kernel = out_w * out_h
    total_out_per_case    = num_kernels * out_pixels_per_kernel
    trunc_bits            = get_trunc_bits(kernel_size)
    num_dsps              = ((kernel_size**2 + 1) // 2) if is_symmetric else kernel_size**2

    mode_desc = {
        1: f"Centrosymmetric  (IS_SYMMETRIC=1, NUM_KERNELS={num_kernels}, {num_dsps} DSPs)",
        2: f"Asymmetric Dual-Patch   (IS_SYMMETRIC=0, NUM_KERNELS={num_kernels}, {num_dsps} DSPs)",
        3: f"Asymmetric Dual-Kernel  (IS_SYMMETRIC=0, NUM_KERNELS={num_kernels}, {num_dsps} DSPs/kernel)",
    }


    print("=" * 65)
    print("  GENERATING TEST VECTORS FOR HARDWARE CONVOLVER")
    print(f"  Mode         : {mode} - {mode_desc[mode]}")
    print(f"  Image Size   : {img_width} x {img_height}  ({img_width*img_height} pixels)")
    print(f"  Kernel Size  : {kernel_size} x {kernel_size}  (NUM_TAPS = {kernel_size**2})")
    print(f"  Output Size  : {out_w} x {out_h}  ({out_pixels_per_kernel} pixels / kernel)")
    print(f"  Num Kernels  : {num_kernels}")
    print(f"  Trunc Bits   : {trunc_bits}")
    print(f"  Test Cases   : {num_cases}  ({total_out_per_case} outputs per case)")
    print(f"  Seed         : {seed}")
    print(f"  Output Dir   : {output_dir}")
    print("=" * 65)

    rng = np.random.default_rng(seed)

    # Normalise path so os.path.join works on Windows drive roots
    if output_dir.endswith(":"):
        output_dir = output_dir + "/"
    os.makedirs(output_dir, exist_ok=True)

    # File paths - mode-tagged (primary) and generic (fallback for testbench)
    def paths(tag):
        return (
            os.path.join(output_dir, f"all_images_{tag}.mem"),
            os.path.join(output_dir, f"all_weights_{tag}.mem"),
            os.path.join(output_dir, f"all_expected_{tag}.mem"),
        )

    tagged   = paths(f"m{mode}")
    generic  = paths("generic")   # all_images_generic.mem  (not used by TB)
    standard = (                  # all_images.mem           (used by TB as fallback)
        os.path.join(output_dir, "all_images.mem"),
        os.path.join(output_dir, "all_weights.mem"),
        os.path.join(output_dir, "all_expected.mem"),
    )

    # Clear existing files
    for p in list(tagged) + list(standard):
        if os.path.exists(p):
            os.remove(p)

    # Generate
    with open(tagged[0], 'w') as fi_t, open(tagged[1], 'w') as fw_t, open(tagged[2], 'w') as fe_t, \
         open(standard[0],'w') as fi_s, open(standard[1],'w') as fw_s, open(standard[2],'w') as fe_s:

        for tc in range(num_cases):
            img = rng.integers(0, 256, size=(img_height, img_width), dtype=np.uint8)

            if is_symmetric:
                kernels = [make_symmetric_kernel(rng, kernel_size)]
            else:
                kernels = make_asymmetric_kernels(rng, num_kernels, kernel_size)

            write_vectors(fi_t, fw_t, fe_t, img, kernels)
            write_vectors(fi_s, fw_s, fe_s, img, kernels)

            # Print first kernel of first test case as a sanity check
            if tc == 0:
                print(f"\n  [TC 1] Sample kernel 0 (flat): {kernels[0].flatten().tolist()}")
                if is_symmetric:
                    flat = kernels[0].flatten()
                    ok   = all(flat[i] == flat[len(flat)-1-i] for i in range(len(flat)))
                    print(f"         Centrosymmetry verified: {ok}")

            sys.stdout.write(
                f"\r  Progress: {tc+1}/{num_cases} cases  "
                f"({(tc+1)*total_out_per_case} expected pixels written)"
            )
            sys.stdout.flush()

    print(f"\n\n{'='*65}")
    print(f"  SUCCESS - {num_cases} test cases for Mode {mode}")
    print(f"  Tagged files  (used by testbench):")
    print(f"    {tagged[0]}")
    print(f"    {tagged[1]}")
    print(f"    {tagged[2]}")
    print(f"  Generic fallback files (used by testbench when no tagged file):")
    print(f"    {standard[0]}")
    print(f"    {standard[1]}")
    print(f"    {standard[2]}")
    print(f"{'='*65}\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Parameterized Golden Model & Test Vector Generator for Hardware Convolver",
        formatter_class=argparse.RawTextHelpFormatter
    )

    parser.add_argument("--mode", "-m", type=str,
                        default=str(DEFAULT_CFG["mode"]),
                        help="1=Centrosymmetric  2=Dual-Patch  3=Dual-Kernel  all=all three")

    parser.add_argument("--img_size", type=int,
                        default=None,
                        help="Square image size (sets both width and height)\n"
                             f"Default: {DEFAULT_CFG['img_width']}  (from CONFIGURATION BLOCK)")

    parser.add_argument("--img_width", type=int,
                        default=DEFAULT_CFG["img_width"],
                        help=f"Image width  (default: {DEFAULT_CFG['img_width']})")

    parser.add_argument("--img_height", type=int,
                        default=DEFAULT_CFG["img_height"],
                        help=f"Image height (default: {DEFAULT_CFG['img_height']})")

    parser.add_argument("--kernel_size", "-k", type=int,
                        default=DEFAULT_CFG["kernel_size"],
                        help=f"Kernel size (square)  (default: {DEFAULT_CFG['kernel_size']})\n"
                              "Supported: 1, 3, 5, 7, 9")

    parser.add_argument("--num_kernels", "-K", type=int,
                        default=DEFAULT_CFG["num_kernels"],
                        help=(f"Number of independent kernels  (default: {DEFAULT_CFG['num_kernels']})\n"
                               "  Mode 1 -> forced to 1  (centrosymmetric, 1 kernel only)\n"
                               "  Mode 2 -> forced to 1  (dual-patch, 1 kernel on 2 patches)\n"
                               "  Mode 3 -> 2, 4, 6 ...  (must be even; hardware does 2 per cycle)"))

    parser.add_argument("--num_cases", "-n", type=int,
                        default=DEFAULT_CFG["num_cases"],
                        help=f"Number of test cases per mode  (default: {DEFAULT_CFG['num_cases']})")

    parser.add_argument("--output_dir", "-o", type=str,
                        default=DEFAULT_CFG["output_dir"],
                        help=f"Output directory for .mem files  (default: {DEFAULT_CFG['output_dir']})")

    parser.add_argument("--seed", "-s", type=int,
                        default=DEFAULT_CFG["seed"],
                        help=f"Random seed  (default: {DEFAULT_CFG['seed']})")

    args = parser.parse_args()

    # img_size overrides both width/height if provided
    if args.img_size is not None:
        args.img_width  = args.img_size
        args.img_height = args.img_size

    # Validate kernel size
    if args.kernel_size not in [1, 3, 5, 7, 9]:
        print(f"[WARNING] kernel_size={args.kernel_size} is non-standard. "
              f"Hardware may not be synthesized for this size.")

    # Validate image vs kernel
    if args.img_width < args.kernel_size or args.img_height < args.kernel_size:
        print(f"[ERROR] Image ({args.img_width}x{args.img_height}) must be >= kernel ({args.kernel_size}x{args.kernel_size})")
        sys.exit(1)

    if args.mode.lower() == "all":
        print("Generating test vectors for ALL three modes...\n")
        for m in [1, 2, 3]:
            generate(
                mode        = m,
                img_width   = args.img_width,
                img_height  = args.img_height,
                kernel_size = args.kernel_size,
                num_kernels = args.num_kernels,
                num_cases   = args.num_cases,
                output_dir  = args.output_dir,
                seed        = args.seed + m,   # different seed per mode
            )
        # The standard all_*.mem files are left as Mode 3 (last to run)
        print("NOTE: The generic all_*.mem files now contain Mode 3 data.")
    else:
        try:
            mode_int = int(args.mode)
        except ValueError:
            print(f"[ERROR] Invalid --mode '{args.mode}'. Use 1, 2, 3, or 'all'.")
            sys.exit(1)

        if mode_int not in [1, 2, 3]:
            print(f"[ERROR] --mode must be 1, 2, 3, or 'all'.  Got: {mode_int}")
            sys.exit(1)

        generate(
            mode        = mode_int,
            img_width   = args.img_width,
            img_height  = args.img_height,
            kernel_size = args.kernel_size,
            num_kernels = args.num_kernels,
            num_cases   = args.num_cases,
            output_dir  = args.output_dir,
            seed        = args.seed,
        )



if __name__ == "__main__":
    main()