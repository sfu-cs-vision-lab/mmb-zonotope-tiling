# Validation checks

The software checks input identity, file consistency, hull volume and
reflectance feasibility. These checks can detect many errors, but they do
not prove vertex extremality or completeness of the enumeration.

The validation functions run in MATLAB on a desktop or cluster. Reflectance
checks need Optimization Toolbox. They operate on existing results and do
not need CUDA or Slurm. The HPC checks below also compute new test results.

## Dataset validation

`validateDataset` checks that:

- The summary names the dataset's generators file and is not marked partial.
- The target color and input payload hash match the generators file.
- CSV dimensions, finite coordinates and face indices are valid.
- The recomputed hull volume matches the summary within `1e-10` relative.
  A flat body, which sensors of rank r below 6 give, must have volume 0, no
  faces and points spanning at most r - 3 dimensions.
- Sampled boundary vertices have reflectances in `[0,1]` that reproduce both
  color signals within the stated tolerance.

The reflectance residual is computed directly from the returned spectrum.
The solver is retried if this residual exceeds the tolerance. A vertex
without an accepted reflectance is recorded as `lp.indeterminate` and the
dataset fails validation. This does not prove that no such reflectance
exists. `lp.infeasible` remains zero because no infeasibility proof is made.

Read `lp.worstResidual`, `lp.acceptanceTolerance` and the failed row indices
when investigating a failure. The size of the residual alone does not
identify its cause.

## Collection validation

`validateCollection` requires every listed dataset to pass. It also compares
volumes for complementary reflectance levels, such as 10% and 90%, within
`1e-9` relative tolerance. Their MMBs are point reflections of one another.

Volume agreement between complementary cases does not rule out an error
shared by both. Reflectance feasibility checks whether tested points can
be produced. It cannot detect missing points. Neither check establishes
completeness of enumeration.

## Checks before computing the full collection

These four checks write `.checks/<name>.PASS` after succeeding. The
collection driver requires all four records to match the current source.
They are not required for an ordinary run through `mmb_run.sh`.

| Check | Where it runs | What it tests |
|---|---|---|
| `tests/hpc/test_example.sh` | Allocated HPC GPU node | Builds and runs the 10 nm example through both job routes, validates it and compares its volume with an independent reference within `1e-12` relative |
| `tests/hpc/test_determinism.sh` | Allocated HPC GPU node | Requires two runs on the same GPU to have identical candidate vertex sets and byte-identical hull vertices and faces |
| `tests/hpc/test_interruption.sh` | HPC login node, submitting real GPU jobs | Cancels a running chunk, checks incomplete output is rejected, resumes the missing work and compares with an uninterrupted run |
| `tools/regenerate_datasets.sh check-inputs` | MATLAB on a desktop or HPC login node | Regenerates all listed inputs and requires identical numeric payloads to those under `STORED_ROOT`. No GPU computation |

`tests/hpc/test_example.sh` compares the example's hull volume with
`1.6197295874216849e+02`, a reference volume computed independently. A run
prints `1.619729587421700e+02`, which agrees with it to 1e-14 relative. The
example's intersecting-tile count is 13,233 and its boundary has 1,976
vertices.
Counts can depend on numerical tolerances. Investigate differences using
the volume, coordinates and diagnostic counters together.

Candidate row order can differ because GPU threads write concurrently.
The determinism check sorts those rows before comparing them. If it fails,
retain the differing rows and record the environment before investigating.

Input comparisons fail on all numeric-payload differences, including small
rounding differences. CPU architecture, MATLAB release and numerical
libraries can affect those results. The checker reports relative
differences to help identify the affected datasets.

## Comparing volumes with the published collection

`compareReference("volumes", runsRoot, "tools/reference_volumes.csv")`
compares each passing certificate's recomputed volume with the published
manifest. Every listed dataset must be present and agree within `1e-9`
relative tolerance in either direction. Run dataset validation first so
the certificates correspond to the current files.

The table covers the 345 published datasets. It is a reproducibility
reference, not an independent proof of the enumeration method.

## Recording the environment

Record the source identifier, MATLAB release, modules, GPU and driver
with a check. Useful cluster commands are:

```sh
hostname
module list 2>&1
bash tools/source_id.sh
nvidia-smi --query-gpu=name,driver_version --format=csv
```

Keep the logs and certificates with the results. The certificate fields
are described in `docs/VALIDATION_FORMAT.md`.

## Supplied validation evidence

The `validation/` directory holds records for individual datasets. Each
subdirectory is named for a dataset_id. For dataset_id
`1931_2deg_D65_A_1nm_refl50` it holds a comparison of the released CUDA
kernel source with the source used for the calculation and the GPU timing
for that dataset.

Two datasets, `1931_2deg_D65_A_1nm_refl50` and
`cfb_10deg_D65_FL11_1nm_refl10`, were checked at every boundary vertex
rather than a sample, by `validateDataset` with `Sample=Inf`. Their
certificates in the data archive record the check. It verifies reflectance
feasibility within tolerance. It does not establish that the enumeration is
complete, and it does not establish that each listed point is extreme.
