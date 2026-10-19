# Exact Metamer Mismatch Body Computation by Zonotope Tiling

[![MATLAB](https://img.shields.io/badge/MATLAB-R2024b--R2025b-blue.svg)](https://www.mathworks.com/products/matlab.html)
[![CI](https://github.com/sfu-cs-vision-lab/mmb-zonotope-tiling/actions/workflows/main.yml/badge.svg)](https://github.com/sfu-cs-vision-lab/mmb-zonotope-tiling/actions)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-green.svg)](LICENSE)

Compute the exact metamer mismatch body (MMB), the set of colors an object
can take under a second illuminant, given its color under a first
illuminant.

The MMB is computed by tiling the six-dimensional double object-color solid
(a zonotope) into parallelotopes, slicing each tile with the target-color
plane, enumerating the cross-section vertices on a GPU and taking the
convex hull of the result. The enumeration is exact for the discretized
problem defined by the generators file. Coordinates are floating point.
When the two mechanisms share a channel, the MMB is flat, and the pipeline
reports it with volume 0 and its distinct points.

The [Zenodo data archive](https://doi.org/10.5281/zenodo.22683533) contains
345 precomputed datasets. This repository provides the computation and
validation software, including the workflow for running new MMBs on a cluster.

## Start here

| What you want to do | Where to start | Where it runs |
|---|---|---|
| Explore and validate a supplied MMB | [MATLAB example](examples/GettingStarted.m) | MATLAB on a desktop or laptop, with Optimization Toolbox |
| Compute a new MMB using the supplied workflow | [Small HPC example](#small-hpc-example-start-to-finish) | A Slurm cluster with an NVIDIA GPU, CUDA and MATLAB |
| Compute the archived collection | [HPC guide](docs/HPC_GUIDE.md) | The same cluster setup |

For the MATLAB example, open `mmb-zonotope-tiling.prj`, then open and run
`examples/GettingStarted.m`. It uses the small result supplied in the
repository. No GPU or cluster connection is needed.

The functions in `src/` also prepare inputs, build hulls from existing
kernel output and validate results in MATLAB. The cluster workflow calls
these functions alongside the CUDA program that enumerates vertices on
the GPU. The job-management scripts use Slurm.

## Terminology

- **collection**: the full set of MMBs defined by `runs/dataset_ids.txt`.
- **dataset**: one MMB, meaning its generators file and its results.
- **dataset_id**: the identifier of one dataset, for example
  `1931_2deg_D65_A_10nm_refl50`. It encodes the observer, the two
  illuminants, the wavelength spacing and the flat-reflectance level.

Every file a dataset owns is named after its `dataset_id`:

```
runs_output/<dataset_id>/
    generators_<dataset_id>.txt      input: the discretized problem
    chunks/                          kernel output, one file per array task
    results/
        mmb_<dataset_id>_vertices.csv
        mmb_<dataset_id>_faces.csv
        mmb_<dataset_id>_summary.txt
        mmb_<dataset_id>_gate.json   validation certificate
        .hull_verified               record written after the hull is checked
    logs/
```

## Requirements

### MATLAB on a desktop or laptop

- MATLAB for preparing inputs, loading and plotting results and building
  hulls from existing kernel output.
- Optimization Toolbox for reflectance validation, including the supplied
  MATLAB example.

These MATLAB operations do not require CUDA or Slurm. The memory needed
for hull construction depends on the size of the existing kernel output.

### HPC computation

- A Slurm cluster with at least one NVIDIA GPU. The workflow was tested on
  H100 (`sm_90`). Other architectures need `MMB_GPU_ARCH` changed in
  `config/cluster.sh`.
- CUDA toolkit with `nvcc` and a host compiler it accepts.
- MATLAB with the Optimization Toolbox. `linprog` is used for the
  reflectance feasibility check. The Parallel Computing Toolbox is optional
  and only speeds up the batch validation job.
- `bash` 4.2 or newer, `python3` 3.8 or newer, `awk` and `sha256sum` or
  `shasum`.

`python3` does two small jobs. `mmb_run.sh` computes the tile count C(n, 6)
with `math.comb` and estimates a GPU walltime from it. `tools/slurm_jobs.sh`
hashes the resolved output directory into a tag, so the launcher recognizes
its own Slurm jobs and leaves other jobs alone. `math.comb` arrived in Python
3.8, which sets the minimum.

`awk` reads single values out of text. It reads the band count at the top of
a generators file, the vertex and face counts and hull volume from a summary,
the chunk count from a result header and row counts in the result CSVs. The
launcher, the job scripts and the checking tools in `tools/` all use it.

Neither is needed for the MATLAB work described above. They belong to the
shell and HPC workflow.

Tested releases are in [Testing](#testing).

## Configure your HPC site

All site settings live in one file, `config/cluster.sh`. The launcher, the
job scripts and the environment checks read it. Edit the values, or export
the same variable names to override them.

```sh
MMB_ACCOUNT_GPU=def-funt_gpu          # Slurm account for GPU jobs
MMB_ACCOUNT_CPU=def-funt_cpu          # Slurm account for hull and validation
MMB_PARTITION=                        # empty means the cluster default
MMB_GPU_GRES=gpu:h100:1               # --gres for one GPU
MMB_EXCLUDE_NODES=                    # optional --exclude node list
MMB_MODULES_GPU="StdEnv/2023 gcc/12.3 cuda/12.2"
MMB_MODULES_MATLAB="StdEnv/2023 matlab/2024b.1"
MMB_GPU_ARCH=sm_90                    # CUDA target architecture
MMB_OUTPUT_ROOT=runs_output           # results location. Point at scratch
```

The shipped values are the ones this workflow was tested on, the Fir
cluster of the Digital Research Alliance of Canada. They are an example.

`--fmad=false` in `cuda/Makefile` is not configurable. The published
numerical results depend on it.

## Small HPC example, start to finish

This runs one 10 nm dataset through generation, enumeration, hull
construction and validation. It takes seconds of GPU time.

```sh
git clone https://github.com/sfu-cs-vision-lab/mmb-zonotope-tiling.git
cd mmb-zonotope-tiling

# 1. Edit config/cluster.sh for your site, then load the toolchain.
source tools/env.sh

# 2. Build the CUDA kernel.
make -C cuda NVCC_ARCH="$MMB_GPU_ARCH"

# 3. Generate the input and submit the job.
bash mmb_run.sh runs/runs_validate_10nm.m

# 4. Watch it.
bash mmb_run.sh --status

# 5. When it reports DONE, read the summary.
cat "$MMB_OUTPUT_ROOT/1931_2deg_D65_A_10nm_refl50/results/"*_summary.txt

# 6. Validate the result against its own generators file.
matlab -batch "addpath('src'); \
  r = validateDataset('$MMB_OUTPUT_ROOT/1931_2deg_D65_A_10nm_refl50'); \
  disp(r.result)"
```

Expected values for `1931_2deg_D65_A_10nm_refl50`:

| Quantity          | Value                    |
|-------------------|--------------------------|
| Boundary vertices | 1976                     |
| Boundary faces    | 3948                     |
| Hull volume       | 1.619729587421700e+02    |
| Certificate       | PASS                     |

The volume is in the normalized coordinate frame recorded in the generators
file header (`white_y100`, perfect-diffuser Y = 100 under each illuminant).
Compare volumes only across datasets that share a normalization.

## Running the HPC workflow

`mmb_run.sh` is the entry point. It runs the requested run definition to
build generators files, then routes each dataset. Small problems go to one
GPU. Large ones are split into a job array of roughly five-minute chunks
with a dependent hull job.

```sh
bash mmb_run.sh runs/runs_survey_1931_2deg.m     # submit
bash mmb_run.sh --status                         # progress
bash mmb_run.sh runs/runs_survey_1931_2deg.m     # resume: safe to repeat
```

Re-running is the recovery path. Completed datasets are skipped, datasets
in flight are left alone and missing chunks or failed hulls are resubmitted
by index.

| Flag | Effect |
|------|--------|
| `--status` | Report every dataset under the output root |
| `--dry-run` | Show routing without submitting |
| `--clean-stale` | Remove lock files for datasets with no jobs in the queue |
| `--heal` | Run `--clean-stale` and cancel jobs stuck on an unsatisfiable dependency |
| `--force-hull` | Rebuild the hull only, keeping kernel output |
| `--force-rerun` | Recompute from the kernel, keeping the generators file |
| `--force-prep` | Regenerate the generators file and recompute everything |
| `--filter PAT` | Only datasets whose id matches the regular expression PAT |
| `--chunks N` | Override the automatic chunk count |
| `--partition P` | Override `MMB_PARTITION` for this invocation |

Canceling one dataset's jobs is part of `--force-rerun` and `--force-hull`.
They cancel that dataset's queued and running jobs before recomputing.

### Choosing what to compute

`runs/*.m` are MATLAB run definitions. Each one calls `prepareGenerators`
for a set of conditions and writes generators files into the current
directory. Running one in MATLAB prepares inputs only. Passing it to
`mmb_run.sh` also submits the HPC computation.

| File | Contents |
|------|----------|
| `runs_validate_10nm.m` | The single 10 nm example above |
| `runs_1nm_d65_a.m` | The single 1 nm dataset `1931_2deg_D65_A_1nm_refl50` |
| `runs_convergence.m` | D65 paired with A, D50 and FL11 at 10, 5, 2 and 1 nm, for `1931_2deg` and `cfb_2deg` |
| `runs_survey_<observer>.m` | D65 paired with every standard illuminant, 1 nm |
| `runs_lightness_<observer>.m` | D65 paired with A, D50 and FL11 at 1 nm across reflectance levels, nine for `1931_2deg` and six for the other observers |
| `runs_observer_comparison.m` | D65 paired with A, D50 and FL11 at 1 nm and 50% reflectance, for all six observers |
| `runs_all_datasets.m` | Every dataset listed in `runs/dataset_ids.txt` |

To regenerate the archived collection, use the driver rather than
`mmb_run.sh` directly. It bounds how many datasets are in flight at once,
which bounds peak scratch usage:

```sh
export STORED_ROOT=/path/to/mmb-data/data
bash tools/regenerate_datasets.sh preflight
bash tools/regenerate_datasets.sh submit --max-datasets 8
bash tools/regenerate_datasets.sh status
bash tools/regenerate_datasets.sh validate
```

`preflight` checks the CIE input hashes, the toolchain and the kernel
build, and reports which release checks have passed for the current source.
`submit` refuses until all four have passed. Run them first:

```sh
bash tests/hpc/test_example.sh                      # GPU node
bash tests/hpc/test_determinism.sh                  # GPU node
bash tools/regenerate_datasets.sh check-inputs  # login node
bash tests/hpc/test_interruption.sh                 # login node
```

Set `STORED_ROOT` to the `data` directory from the extracted Zenodo data
archive. The input comparison requires all 345 generators files. See
[HPC_GUIDE.md](docs/HPC_GUIDE.md) for the full procedure.

These four checks are required by the collection driver. Ordinary runs
through `mmb_run.sh` still check input identity, chunk completeness and
hull outputs. Run `validateDataset` afterward for reflectance feasibility.

### Writing your own run definition

```matlab
prepareGenerators("1931_2deg", "D65", ["A", "FL11"], ...
    Spacing=10, Refl=0.5, DataDir="data");
```

`help prepareGenerators` lists the options, including explicit target
tristimulus values, a reflectance spectrum instead of a flat level, custom
illuminant CSVs and batch inputs.

A reflectance spectrum is interpolated onto the wavelengths the generators
retain, then averaged within each band to one reflectance per band. The
target is those band reflectances applied to the normalized generators, so a
constant spectrum gives the same target as the equal `Refl` value. The
spectrum must cover the retained range, and is never extrapolated.

## How results are checked

The workflow checks input identity and file contents before accepting
kernel output. Validation then checks the resulting hull.

1. `prepareGenerators` writes the generators file and stamps the SHA-256 of
   its numeric payload into the header.
2. The CUDA kernel copies that header into its output, so every chunk
   carries the identity of the problem it solved.
3. `tools/verify_chunk.sh` checks that identity, the chunk index, the row
   count against the header, that every row is three finite
   numbers and that the completion footer is present. Only then is the
   staged file renamed to its canonical name.
4. `slurm/hull_job.sh` re-checks every chunk, requires the set to be
   complete and refuses any file belonging to another dataset. `hullMMB`
   independently repeats the provenance and completeness checks and
   re-reads its own output to confirm the volume.
5. `validateDataset` checks input identity and file consistency, recomputes
   the hull volume and looks for a bounded reflectance witness for
   sampled boundary vertices. It writes `mmb_<dataset_id>_gate.json`.
6. `validateCollection` runs `validateDataset` over `runs/dataset_ids.txt`,
   compares volumes for complementary reflectance levels and writes
   `collection_certificate.json` and `manifest_gated.txt`.

A certificate records the source used for its checks. When the checks run
in this project's Git checkout, that is the commit. In an extracted release
it is the packaged source record. See `tools/source_id.sh`. Two supplied
certificates, those checked at every boundary vertex, were written by the
code of this release and name its commit. The others keep the source
identifiers recorded when they were written. See
`docs/VALIDATION_FORMAT.md`.

Validation does not establish that every listed vertex is extreme or
that the enumeration is complete. `docs/VALIDATION.md` says what
each check does and does not cover, and `docs/VALIDATION_FORMAT.md`
documents the certificate fields.

The `validation/` directory holds a comparison of the released CUDA source
with the source used for the calculation and the GPU timing of dataset_id
`1931_2deg_D65_A_1nm_refl50`. See
[`validation/README.md`](validation/README.md).

### Reading a certificate

`readValidationReport` reads a certificate and returns it as a struct. A
dataset certificate names its dataset in `dataset_id`:

```matlab
r = readValidationReport("results/mmb_1931_2deg_D65_A_10nm_refl50_gate.json");
disp(r.dataset_id)
```

## Batch validation on the HPC

To validate every dataset under the output root as a Slurm job:

```sh
. config/cluster.sh
sbatch --account="$MMB_ACCOUNT_CPU" slurm/validate_job.sh
```

Results land in `<output root>/_validation/`.

## Supported observers

| Short name | Description | Source |
|------------|-------------|--------|
| `1931_2deg` | CIE 1931 2-degree standard observer | ISO/CIE 11664-1:2019 |
| `1964_10deg` | CIE 1964 10-degree standard observer | ISO/CIE 11664-1:2019 |
| `cfb_2deg` | CIE 170-2 cone-fundamental-based 2-degree | CIE 170-2:2015 |
| `cfb_10deg` | CIE 170-2 cone-fundamental-based 10-degree | CIE 170-2:2015 |
| `lms_2deg` | LMS cone fundamentals, 2-degree | CIE 170-2:2015 Table 10.2 |
| `lms_10deg` | LMS cone fundamentals, 10-degree | CIE 170-2:2015 Table 10.5 |
| `<file>.csv` | Custom observer, four columns. See below |

XYZ-family observers are normalized so that a perfect diffuser has Y = 100
under each illuminant. LMS observers keep the unit-peak cone fundamentals.

### Custom observer

The observer argument also accepts a path to your own CSV, in the same way
the second illuminant does. The file has no header. Its four columns are the
wavelength in nm, then three color-matching functions or channel
sensitivities.

```
380,0.0014,0.0000,0.0065
390,0.0042,0.0001,0.0201
400,0.0143,0.0004,0.0679
```

Wavelengths must increase strictly, with no repeats, and every value must be
finite. The three channels may be negative, since color-matching functions
are signed. The file must overlap the wavelength range you ask for.

A custom observer needs `ObserverNorm`, because nothing about an arbitrary
file says what its units are:

| `ObserverNorm` | Effect |
|----------------|--------|
| `"white_y100"` | Scale each illuminant so the second channel of a perfect reflector integrates to 100. Use this for XYZ-like color-matching functions |
| `"as_supplied"` | Use the channel values unchanged, with no white anchor |

The dataset identifier comes from the file base name, made into a valid
identifier, so a path never appears in a dataset name. `my camera.csv`
becomes `myCamera`. The generators header records the source path, its
SHA-256 and the normalization. No DOI, CIE metadata or license is claimed
for a file you supply.

A custom observer fills the same single observer role as a named one. It does
not let you use a different observer for each illuminant.

Prepare inputs in MATLAB:

```matlab
addpath("src");
prepareGenerators("my_camera.csv", "D65", "A", ...
    Spacing=10, Refl=0.5, ObserverNorm="as_supplied", ...
    OutputDir="runs_output/my_camera_D65_A_10nm_refl50");
```

That writes a generators file and computes nothing else. To compute the body
on a cluster, put the same call in a run definition under `runs/`, then hand
it to the launcher. Keep the CSV in the repository root or beside the run
definition, so it resolves when the launcher runs MATLAB from its private
preparation directory:

```matlab
% runs/runs_my_camera.m
prepareGenerators("my_camera.csv", "D65", "A", ...
    Spacing=10, Refl=0.5, ObserverNorm="as_supplied");
```

```sh
bash mmb_run.sh runs/runs_my_camera.m
```

The launcher prepares the inputs, then submits the GPU and hull jobs. See
[Computing the collection on a cluster](docs/HPC_GUIDE.md) for the cluster
setup that has to be in place first.

## Supported illuminants

| Name | Source |
|------|--------|
| `A` | CIE standard illuminant A (ISO/CIE 11664-2:2022) |
| `D50`, `D65` | CIE daylight illuminants (ISO/CIE 11664-2:2022) |
| `E` | Equal energy, computed rather than tabulated |
| `FL1` to `FL12`, `FL3.1` to `FL3.15` | CIE fluorescent (CIE 015:2018) |
| `LED-B1` to `LED-B5`, `LED-BH1`, `LED-RGB1`, `LED-V1`, `LED-V2` | CIE LED (CIE 015:2018) |
| `<file>.csv` | Custom illuminant with two columns, wavelength in nm and relative power |

## Scale

The table gives GPU times on NVIDIA H100 GPUs, taken from the published
summaries and, for 1 nm, from
`validation/1931_2deg_D65_A_1nm_refl50/gpu_timing.md`. Datasets with the
same band count can take very different times, so the table is a rough
guide. `mmb_run.sh` routes datasets by an estimate at 0.38 billion tiles per
second. The band counts are for the CIE 1931 observer over 380 to 780 nm,
counting only complete bins. Other observers can have a shorter range.

| Spacing | Bands | Tiles, C(n,6) | One GPU | Routing |
|---------|-------|---------------|---------|---------|
| 10 nm | 40 | 3.8 million | under 1 s | single GPU |
| 5 nm | 80 | 301 million | under 1 s | single GPU |
| 2 nm | 200 | 82.4 billion | about 2 to 5 min | single GPU |
| 1 nm | 401 | 5.56 trillion | about 4 hr | chunked array |

The largest band count is 410, set by `MAX_N` in `cuda/mmb_exact_cuda.cu`.
A generators file with more bands than that is rejected rather than computed.

## Which tool to use

| Tool | Purpose | Where it runs |
|---|---|---|
| `examples/GettingStarted.m` | Load, plot and validate a supplied MMB | MATLAB, with Optimization Toolbox |
| `src/*.m` | Prepare inputs, build hulls and read or validate results | MATLAB on a desktop or cluster. Reflectance validation needs Optimization Toolbox |
| `runs/*.m` | Define conditions and prepare input files | MATLAB. These scripts do not submit jobs themselves |
| `mmb_run.sh` | Generate inputs, submit jobs, show status and resume work | HPC login node, with GPU and CPU jobs submitted to Slurm |
| `tools/regenerate_datasets.sh` | Manage computation of the published collection | HPC for job management. See the input-check note below |
| `slurm/single_gpu.sh` and `slurm/gpu_chunk.sh` | Compute candidate vertices | HPC GPU jobs called by the launcher |
| `slurm/hull_job.sh` and `slurm/validate_job.sh` | Build hulls and validate results in MATLAB | HPC CPU jobs |
| `tools/slurm_jobs.sh` | Match queued jobs to the current output directory | HPC shell helper used by the launcher |
| `tools/env.sh` and `tools/check_env.sh` | Load and check the configured cluster tools | HPC terminal |
| `tests/hpc/test_example.sh` and `tests/hpc/test_determinism.sh` | Compute and check small MMBs on a GPU | An allocated HPC GPU node |
| `tests/hpc/test_interruption.sh` | Check cancellation and recovery of GPU jobs | HPC login node. Submits and cancels real test jobs |
| `tools/copy_generators.sh` | Copy supplied generators into a new output directory | Local or HPC terminal, with the data archive extracted |
| `tools/check_data_hashes.sh` | Check the CIE input files | Local or HPC terminal, with the files available |
| `tools/verify_chunk.sh` and `tools/check_dataset_files.sh` | Inspect existing inputs and output files | Local or HPC terminal, with the files available |
| `tools/source_id.sh` | Report the identity of the source tree | Local or HPC terminal |
| `tools/find_low_vertex_datasets.sh` | Flag unusually low vertex counts for inspection | Local or HPC terminal, with the results available |

The file-inspection commands require shell utilities, not MATLAB, CUDA
or Slurm. The collection driver's `check-inputs` command uses MATLAB to
regenerate input files and compare them with the supplied data. It can
run without a GPU or scheduler and does not compute MMBs.

Job status and cancellation apply only to jobs submitted for the configured
output directory, so separate output directories can run the same dataset.
If the queue cannot be read, the requested status or recovery operation
stops before treating a dataset as inactive.

## Project structure

```
mmb-zonotope-tiling/
|-- config/cluster.sh          site settings, read by everything
|-- src/
|   |-- prepareGenerators.m    CIE tables -> generators_<dataset_id>.txt
|   |-- hullMMB.m              kernel output -> vertices, faces, summary
|   |-- verifyMMB.m            geometry, provenance, reflectance feasibility
|   |-- findReflectanceWitness.m
|   |-- validateDataset.m      one dataset -> certificate
|   |-- validateCollection.m   whole collection -> certificate + manifest
|   |-- readValidationReport.m reads a certificate and returns it
|   `-- compareReference.m    input and volume comparisons with the reference
|-- cuda/                      CUDA kernel and Makefile
|-- slurm/                     job scripts: single GPU, chunk array, hull, validation
|-- tools/                     environment, input copying, file checks, diagnostics
|-- runs/                      MATLAB run definitions
|   `-- dataset_ids.txt        the collection definition
|-- tests/                     MATLAB unit tests and supplied test data
|   |-- shell/                tests using simulated cluster commands
|   `-- hpc/                  tests that run real GPU jobs
|-- examples/GettingStarted.m  explore a supplied MMB in MATLAB
|-- data/                      CIE tables and their metadata (CC BY-SA 4.0)
|-- docs/                      HPC instructions and validation reference
|   `-- HPC_GUIDE.md           computing the collection on a cluster
|-- validation/                kernel source comparison and GPU timing of one dataset
|-- .github/workflows/main.yml continuous integration, MATLAB and shell tests
|-- buildfile.m                buildtool tasks for static analysis and unit tests
|-- CITATION.cff               citation metadata
|-- LICENSE                    GNU Affero General Public License v3.0
`-- mmb_run.sh                 the entry point
```

## Testing

**MATLAB tests:** run in MATLAB with Optimization Toolbox. No HPC is needed.

```matlab
buildtool          % static analysis, then unit tests
```

**Shell tests:** run in a local terminal with the required shell utilities.
They simulate the cluster commands and do not submit jobs or run CUDA.

```sh
for t in tests/shell/*.sh; do bash "$t"; done
```

**HPC tests:** `tests/hpc/test_example.sh`, `tests/hpc/test_determinism.sh` and
`tests/hpc/test_interruption.sh` perform real GPU computations. Their required
node types are listed above. See [HPC_GUIDE.md](docs/HPC_GUIDE.md) for the commands.

The MATLAB unit tests use the repository's supplied test data.
`validateAllMMBTest` checks completed results and skips itself when no output
is present.

The MATLAB releases and computing environments tested are recorded in
`TESTING.json` in the code archive, together with the compiler, CUDA
version and GPU used. CI covers R2024b through R2025b.

## License

Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

Licensed under the
[GNU Affero General Public License v3.0 or any later version](LICENSE).

The CIE tables in `data/` are used under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Their
metadata, DOIs and license statements travel with them. See
`data/README.md`.

The generated MMB datasets in the Zenodo archive are licensed under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## Citation

The presentation, the archived dataset and this software are separate
works. Cite whichever you used. The Zenodo DOI identifies the archived
dataset. It is not a DOI for the presentation or for the software.

### Presentation and extended abstract

Alexander G. Forsythe and Brian Funt. What's the Right Answer Anyway? Exact
Computation of Metamer Mismatch Bodies via Zonotope Tiling. 34th Color and
Imaging Conference (CIC34), Barcelona, Spain, 2026. Extended abstract.
Accepted for presentation.

```bibtex
@misc{forsythe2026mmbpaper,
  author       = {Forsythe, Alexander G. and Funt, Brian},
  title        = {What's the Right Answer Anyway? Exact Computation of Metamer Mismatch Bodies via Zonotope Tiling},
  howpublished = {34th Color and Imaging Conference (CIC34), Barcelona, Spain},
  year         = {2026},
  note         = {Extended abstract. Accepted for presentation}
}
```

### Dataset

The archived metamer mismatch bodies and their validation records, on Zenodo
under CC BY-SA 4.0.

```bibtex
@dataset{forsythe2026mmbdata,
  author    = {Forsythe, Alexander G. and Funt, Brian},
  title     = {Exact Discrete Metamer Mismatch Bodies from Zonotope Tiling},
  year      = {2026},
  publisher = {Zenodo},
  doi       = {10.5281/zenodo.22683533},
  license   = {CC-BY-SA-4.0}
}
```

### Software

Version 1.0.0 of this repository, under AGPL-3.0-or-later.

```bibtex
@software{forsythe2026mmbsoftware,
  author  = {Forsythe, Alexander G. and Funt, Brian},
  title   = {Exact Metamer Mismatch Body Computation by Zonotope Tiling},
  year    = {2026},
  version = {1.0.0},
  url     = {https://github.com/sfu-cs-vision-lab/mmb-zonotope-tiling},
  license = {AGPL-3.0-or-later}
}
```
