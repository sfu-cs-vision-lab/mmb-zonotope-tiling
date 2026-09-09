# GPU timing for dataset_id 1931_2deg_D65_A_1nm_refl50

## Hardware and what was measured

The enumeration for this dataset is divided into 49 independent parts.
Each part uses one NVIDIA H100 GPU. We report the sum of the per-part
GPU times.

Each part reports the time its enumeration kernel spent on the GPU. A summed
GPU time is not an elapsed duration and does not mean that 49 GPUs ran at
once.

## Summed GPU times

Five complete 49-part runs of this dataset are on record.

    run   summed GPU time   GPU-hours
    1          15476.08 s       4.299
    2          14990.48 s       4.164
    3          14995.17 s       4.165
    4          14886.15 s       4.135
    5          14914.27 s       4.143

The five runs span 4.135 to 4.299 GPU-hours. The figure to quote for this
dataset is approximately 4 GPU-hours of summed GPU time on H100 hardware.

The records do not attribute any one of these runs to the distributed geometry.
The available timing records are not sufficient to make that attribution, and
the choice of run does not change the quoted figure.

## Collected vertex count

The per-part counts from one recorded run sum to 126,444,348, matching
the `raw_vertices` value in the distributed summary. This confirms
agreement in the number of collected vertices. It does not establish
that their coordinates are identical.
