# Computing the collection on a cluster

This guide is for the Slurm HPC workflow. It needs a cluster with NVIDIA
GPUs, CUDA and MATLAB. Submission and status commands run on a login node.
The example and determinism checks run in a GPU allocation, as labeled below.
Run the commands from the repository root.

This guide covers the datasets in `runs/dataset_ids.txt`. For one new MMB, start
with the [small HPC example](../README.md#small-hpc-example-start-to-finish).
To explore an existing result on a desktop or laptop, use the
[MATLAB example](../examples/GettingStarted.m).

## Configure the environment

Edit `config/cluster.sh` for your account, modules, GPU and output location.
Then load the configured tools in each new shell:

```sh
source tools/env.sh
```

Use the same GPU architecture and toolchain when comparing repeated runs.
The published results used `--fmad=false`. Keep that compiler setting.
The source identifier, input hashes and validation records identify the
code and data used for each check.

Input comparisons require identical numeric payloads. Floating-point
results can vary with MATLAB, CPU architecture and numerical libraries.
The input check reports the size of any difference and fails on all
differences. It does not promise identical results on every platform.

An independent check on Apple silicon with MATLAB R2025b reproduced 239
of the 345 input payloads exactly. The other 106 were all LMS datasets,
with a largest relative difference of about 2.1e-15. LMS inputs use a
matrix inverse to derive cone fundamentals. Such small differences are
consistent with floating-point rounding. All 345 matched exactly on Fir
with MATLAB R2024b. These results describe those two environments only.

A failed input check blocks `regenerate_datasets.sh submit`.
`restamp --force` updates an existing passing record after a source change.
It does not create a passing record for a failed input check. To compute
the archived problems using the supplied inputs, use the route at the end
of this guide.

## Check the setup

Download and extract `mmb-data.zip` from
[Zenodo](https://doi.org/10.5281/zenodo.22683533). Set `STORED_ROOT` to its
`data` directory, using an absolute path:

```sh
export STORED_ROOT=/path/to/mmb-data/data
bash tools/regenerate_datasets.sh preflight
```

The driver checks the CIE files, environment and kernel build. Before
submitting the full collection, run these four checks on the current source.
Run the first two inside a GPU allocation:

```sh
salloc --account="$MMB_ACCOUNT_GPU" --gres="$MMB_GPU_GRES" --mem=64G --time=00:30:00
source tools/env.sh
bash tests/hpc/test_example.sh
bash tests/hpc/test_determinism.sh
```

Run the other two from a login node with the same configuration:

```sh
source tools/env.sh
export STORED_ROOT=/path/to/mmb-data/data
bash tools/regenerate_datasets.sh check-inputs
bash tests/hpc/test_interruption.sh
```

The interruption test submits and cancels its own test jobs. It refuses to
run if its test dataset already contains verified results. Queue waits can
dominate its runtime.

Each successful check writes `.checks/<name>.PASS` with its source
identifier. Collection submission requires all four records to match the
current source. See `docs/VALIDATION.md` for the checks and their limits.

## Start with two datasets

```sh
bash tools/regenerate_datasets.sh submit --max-datasets 2
bash tools/regenerate_datasets.sh status
```

Measure scratch usage while the jobs run. Choose the full-run limit from
the largest observed dataset size and the space available. Leave a margin
for variation. `--max-datasets` limits how many datasets are in progress.

## Submit and resume

```sh
bash tools/regenerate_datasets.sh submit --max-datasets 8
bash tools/regenerate_datasets.sh status
bash tools/regenerate_datasets.sh check-files
```

Run `submit` again to fill available slots. Use only one submission loop
at a time. Completed datasets are skipped and missing chunks or failed
hull jobs are resubmitted.

Large datasets are divided into chunks. Each kernel writes to a staging
file, which is checked before being renamed to its result filename. The
hull job checks the complete chunk set again. It deletes chunks only
after checking the written hull and saving `.hull_verified`.

An interrupted write does not distinguish a timeout from preemption.
Retries therefore keep the same walltime estimate. For repeated failures,
inspect the logs and the `sacct` command printed by the launcher.
`MMB_CHUNK_WALL_MINS` overrides the estimate, capped at `MMB_CHUNK_WALL_MAX_MINS`.
For quota problems, free space or reduce `--max-datasets` before resuming.

To delete and recompute one dataset's outputs:

```sh
bash tools/regenerate_datasets.sh redo <dataset_id> --yes
```

Job cancellation is asynchronous. Confirm that the dataset's canceled
jobs have stopped before resuming other work in its directory.

## Validate and compare

After all datasets finish:

```sh
bash tools/regenerate_datasets.sh validate --sample 1024
matlab -batch "addpath('src'); \
  r = compareReference('volumes', \"$MMB_OUTPUT_ROOT\", 'tools/reference_volumes.csv'); \
  exit(double(~r.pass))"
```

Inspect any failed or missing dataset before proceeding. The volume table
contains the values in the published manifest. Every dataset must agree
within `1e-9` relative tolerance in either direction.

Keep the result files, dataset certificates and `gate_reports/` together.
`docs/VALIDATION_FORMAT.md` describes their fields. Validation checks input
identity, file consistency, volume agreement and sampled reflectance
feasibility. It does not prove that enumeration found every vertex.

## Source changes during a run

Rerun the checks after changing source files. In a Git checkout,
`bash tools/regenerate_datasets.sh restamp` can update a saved check when
none of the files it covers changed. Otherwise it lists the files and
requires the check to run again. An explicit `restamp --force <check>
"<reason>"` records an override. `restamp` updates a check that already
passed. It does not create a passing record for a check that failed.

An extracted archive has no Git history, so its checks must be rerun. The
source record must belong to the software directory itself. An archive
extracted inside an unrelated Git repository is identified by its packaged
record, not by the enclosing repository's commit.

## Compute from the supplied generator files

This route uses `mmb_run.sh` directly with the archived inputs. It does not
require regenerated inputs to be identical and does not create a passing
regeneration-check record. Run the example, determinism and interruption
checks for your cluster before starting a large computation.

First verify the extracted data archive using its `DATA_SHA256SUMS.txt`.
Set `STORED_ROOT` to its `data` directory and choose a new output directory.
From the software root, copy only the generator files:

```sh
export STORED_ROOT=/path/to/mmb-data/data
export MMB_OUTPUT_ROOT=/scratch/your-account/mmb_from_supplied_inputs
bash tools/copy_generators.sh "$STORED_ROOT" "$MMB_OUTPUT_ROOT"
```

The helper checks that all listed inputs exist and carry payload hashes
before copying. It copies only the generator files and refuses an existing
output directory. It runs in a terminal without MATLAB, a GPU or Slurm.
After it completes, start with the small example:

```sh
bash mmb_run.sh --filter '^1931_2deg_D65_A_10nm_refl50$' runs/runs_all_datasets.m
bash mmb_run.sh --status
```

The launcher keeps each supplied generator file because it already has a
payload hash. It discards the newly prepared copy for that dataset. Use
`--filter` to submit additional datasets in manageable groups and repeat
the same command to resume them. Avoid `--force-prep` on this route because
it replaces the supplied inputs. Do not copy archived results into the
new output directory, since completed results would be skipped.

Use the validation and volume-comparison commands above when the runs
finish. The collection driver's `submit` command remains unavailable if
its regenerated-input check has not passed.
