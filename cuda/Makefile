# Build the CUDA candidate-enumeration kernel.
#
#   make                    build with the default architecture
#   make NVCC_ARCH=sm_80    build for another GPU
#   make test               run the committed 10 nm example at sensor
#                           rank 6, 5, 4 and 3
#
# Load the toolchain first. On the tested cluster:
#   . config/cluster.sh && module load $MMB_MODULES_GPU
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

NVCC = nvcc

# GPU architecture. sm_90 is H100, sm_80 is A100, sm_70 is V100.
# config/cluster.sh sets MMB_GPU_ARCH, the launcher passes it in here.
NVCC_ARCH ?= sm_90

# --fmad=false disables fused multiply-add contraction. The published
# results depend on it, changing it changes the numbers.
NVCC_FLAGS = -O3 -arch=$(NVCC_ARCH) --fmad=false
LIBS = -lm

TARGET = mmb_exact
SRC = mmb_exact_cuda.cu
TEST_DATASET_ID = 1931_2deg_D65_A_10nm_refl50
TEST_IDS = $(TEST_DATASET_ID) $(TEST_DATASET_ID)_rank5 $(TEST_DATASET_ID)_rank4 \
	$(TEST_DATASET_ID)_rank3

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(NVCC) $(NVCC_FLAGS) -o $@ $< $(LIBS)

# Enumerate candidates for the committed 10 nm test fixture, and for its
# rank 5, 4 and 3 forms, in which the second mechanism shares one, two or
# all three channels with the first. Check the output with
# tools/verify_chunk.sh, see README.md.
test: $(TARGET)
	for id in $(TEST_IDS); do \
		./$(TARGET) --data ../tests/fixtures/generators_$$id.txt \
			--output mmb_$$id.txt || exit 1; \
	done

clean:
	rm -f $(TARGET) $(TEST_IDS:%=mmb_%.txt)
