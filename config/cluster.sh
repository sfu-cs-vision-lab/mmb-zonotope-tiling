# config/cluster.sh  Site settings for the Slurm workflow.
#
# Sourced by mmb_run.sh, tools/regenerate_datasets.sh, tools/env.sh,
# tools/check_env.sh and the job scripts in slurm/. It is the only place
# these settings are defined. Edit the values, or export the same variable
# names before running, which takes precedence over the values here.
#
# The defaults are the configuration this workflow was tested on, the Fir
# cluster of the Digital Research Alliance of Canada, with H100 GPUs. They
# are an example, not a requirement.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

# Slurm accounts. GPU jobs enumerate candidates. CPU jobs build hulls and
# run validation.
MMB_ACCOUNT_GPU=${MMB_ACCOUNT_GPU:-def-funt_gpu}
MMB_ACCOUNT_CPU=${MMB_ACCOUNT_CPU:-def-funt_cpu}

# Partition. Empty means the cluster default.
MMB_PARTITION=${MMB_PARTITION:-}

# GPU request passed as --gres. One GPU per job.
MMB_GPU_GRES=${MMB_GPU_GRES:-gpu:h100:1}

# Comma-separated node list passed as --exclude. Empty means no exclusions.
# Use it to keep jobs off nodes that are known bad at your site.
MMB_EXCLUDE_NODES=${MMB_EXCLUDE_NODES:-}

# Modules. MMB_MODULES_GPU must provide nvcc and a matching host compiler.
# MMB_MODULES_MATLAB must provide the matlab command.
MMB_MODULES_GPU=${MMB_MODULES_GPU:-"StdEnv/2023 gcc/12.3 cuda/12.2"}
MMB_MODULES_MATLAB=${MMB_MODULES_MATLAB:-"StdEnv/2023 matlab/2024b.1"}

# Strings that check_env.sh looks for in the resolved gcc, nvcc and matlab.
# Keep them consistent with MMB_MODULES_GPU and MMB_MODULES_MATLAB.
MMB_EXPECT_GCC=${MMB_EXPECT_GCC:-" 12\.3"}
MMB_EXPECT_NVCC=${MMB_EXPECT_NVCC:-"release 12.2"}
MMB_EXPECT_MATLAB=${MMB_EXPECT_MATLAB:-"2024b"}

# CUDA target architecture. Sm_90 is H100. Sm_80 is A100. Sm_70 is V100.
# The Makefile also applies --fmad=false, which the published numerical
# results depend on. Do not remove it.
MMB_GPU_ARCH=${MMB_GPU_ARCH:-sm_90}

# Where per-dataset working directories and results are written. Point this
# at scratch if your home filesystem has a small quota. A relative path is
# resolved against the repository root.
MMB_OUTPUT_ROOT=${MMB_OUTPUT_ROOT:-runs_output}

# Walltime for one GPU chunk is computed from the tile count. These bound it.
MMB_CHUNK_WALL_MIN_MINS=${MMB_CHUNK_WALL_MIN_MINS:-10}
MMB_CHUNK_WALL_MAX_MINS=${MMB_CHUNK_WALL_MAX_MINS:-170}
