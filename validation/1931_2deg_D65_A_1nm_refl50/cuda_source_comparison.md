# CUDA source comparison

This record compares the CUDA source used for the calculation that produced
the 345 distributed datasets with the released source, `cuda/mmb_exact_cuda.cu`.
The two files are not byte-identical. This record says how they relate.

## Sources compared

    source used for the calculation
        679ac616c9f908ee962841ad8c8ffe4bee8ba4b7b969e625c25cc6d1ece844b1

    released source, cuda/mmb_exact_cuda.cu
        dcca72abc29576d3ec745f47a677104e121d4cbb5012972221e07b60cbb5956b

The source used for the calculation is byte-identical to the copy preserved
from the compute cluster, so one hash stands for both.

Reduced to their code, by removing C comments, collapsing each run of
whitespace to one space and dropping blank lines, the source used for the
calculation has 596 lines and the released source 728. Of the 596, 491
appear unchanged in the released source, in the same order.

## One kernel

The source used for the calculation has one kernel, `mmb_kernel`, for six
sensors of rank 6, and a tile is a set of six wavelengths. The released
source has one kernel, `mmb_kernel<R>`, a template on the rank R of the six
sensors, and a tile is a set of R wavelengths. The program finds R by the
rule MATLAB's `rank` uses, counting the singular values above max(n, 6)
times the floating-point spacing at the largest one. One line of standard
output reports R. The program launches `mmb_kernel<R>` for R = 6, 5, 4 or
3, and stops if R is below 3.

The template is `mmb_kernel` with each fixed 6 that counts the wavelengths
of a tile written as R. The slice of a tile by the target color then has
dimension R - 3. Each vertex of the slice has R - 3 coordinates at 0 or 1
and three free, so it lies on R - 3 of the 2R planes t = 0 and t = 1. At
rank 6 these are the triples of 12 planes that `mmb_kernel` tests.

## At rank 6

At rank 6 the generators go to `mmb_kernel<6>` as read. `mmb_kernel<6>`
performs the same floating-point operations as `mmb_kernel`, in the same
order, with the same thresholds and acceptance conditions. Its source
differs from `mmb_kernel` only in these ways:

- A 6 that counts tile wavelengths is written R, 12 is 2R, 5 is R - 1 and
  4 is R - 2. A 3 that counts the dimensions of the slice, which are the
  columns of its null-space basis and the planes in a set, is written
  K = R - 3. Arrays indexed by the six sensors keep 6, written D.
- The 3 x 3 system for a vertex is filled in a loop over the K planes of a
  set, and t = t0 + N s is summed in a loop over K. At K = 3 these loops
  make the same loads, products and sums, in the same order, as the
  written-out expressions in `mmb_kernel`.
- The LU helpers are templates on R. The vertex solve is `solve_k<K>`,
  and `solve_k<3>` calls `solve3`.
- Some names differ. `lu6` is `lu`, `N6` is `NS` and `d_triples` is
  `d_plane_sets`. The loop over plane sets runs to C(2R, R - 3), a
  compile-time constant that is 220 at rank 6, as `NTRIPLES` is.
- Two expressions are written differently and have the same value at rank
  6. One is `sizeof(LU)` for `sizeof(GB)`, 288 bytes in both. The other is
  `{0}` for six zeros in one initializer.

The host builds the table of plane sets with `unrank_lex`, the function the
kernel uses to find the wavelengths of a tile. At rank 6 the table holds the
220 triples of `mmb_kernel` in the same order. Apart from the rank test and
its line of standard output, the host at rank 6 passes the kernel the same
data as the source used for the calculation, and writes the output file in
the same format. All 345 distributed datasets have sensor rank 6.

## Below rank 6

Below rank 6 every tile of six wavelengths is singular, and the program
runs `mmb_kernel<R>`. The host first reorders the three channels of the
second mechanism. The rows of the generators are then the three channels of
the first mechanism, R - 3 channels of the second and the other 6 - R
channels. With the first three, those R - 3 channels span the space all six
sensors span. The host chooses
the channels moved to the end from the dependences among the six sensors,
so that each is a combination of the rows before it. Apart from the stop
below rank 3 and the choice of kernel at launch, this reordering is the
only host step that runs at some ranks and not at others.

The tile is the first R rows at R wavelengths. The response of the second
mechanism at a slice vertex is computed from its three channels as read, as
at rank 6. The output lists the channels in their original order and has
the header line `% rank=R, tiles of R wavelengths`.

The template uses three functions that rank 6 does not:

- `solve_k<2>` and `solve_k<1>` solve the 2 x 2 and 1 x 1 systems by
  Cramer's rule, as `solve3` solves the 3 x 3, with the same 1e-15 bound on
  the determinant.
- `solve_k<0>` returns 1, the determinant of the empty system. At rank 3
  the slice of a tile is the single point t0.

A tile contributes its slice vertices when there are at least R - 2 of them,
the number a slice of dimension R - 3 needs. At rank 6 that is 4, as in
`mmb_kernel`.

## Checks

Both sources were compiled with nvcc 12.2 for sm_90 with the Makefile's
flags, -O3 and --fmad=false. The machine code (SASS) of `mmb_kernel<6>` and
of `mmb_kernel` is the same 4,488 instructions, encodings included, using
249 registers and a 1,520-byte stack frame.

Both sources were also built for the CPU, with each kernel launch run as a
serial loop over its threads and floating-point contraction off. On the
10 nm example, `1931_2deg_D65_A_10nm_refl50`, the two give the same 106,564
vertex rows in the same order, and their output files differ only in the
timing line.

On that CPU build the released source was also run on the rank 5, 4 and 3
forms of the example, in which one, two or all three channels of the second
mechanism are those of the first. In 1,000 directions, the support functions
of the rank 5 and rank 4 bodies agree with those of reference bodies,
computed by a separate implementation of the tiling, within 1.65e-15 and
1.14e-15 of the largest coordinate. The rank 3 body is one point, equal to
the target color within one unit in the last place.

## Conclusion

At rank 6 the two sources perform the same numerical operations, with the
same thresholds and acceptance conditions. Their file hashes differ because
of their comments, the names and the template form of the kernel and its
helpers, the name of one host variable used to build output filenames, the
rank test and the code for sensor rank below 6.

The comparison of machine code holds for that compiler, those flags and
that target. Compiled binaries in general also depend on the compiler, its
version, its flags and the target architecture.
