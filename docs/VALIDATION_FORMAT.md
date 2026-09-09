# Validation certificate schema

Validation writes machine-readable evidence next to the results, so a
result can be checked without recomputing it. There are two levels.

## Dataset certificate

Path: `<output root>/<dataset_id>/results/mmb_<dataset_id>_gate.json`

Schema id: `mmb-dataset-report/2`. Written atomically by
`src/validateDataset.m`.

| Field | Meaning |
|---|---|
| `schema` | `mmb-dataset-report/2` |
| `dataset_id` | The dataset identifier, taken from the name of the dataset directory. Validation stops if that directory has no `generators_<dataset_id>.txt`. The result files are found by this identifier, which is never read from their names |
| `result` | `PASS` or `FAIL`. Only a PASS dataset enters the manifest of passing datasets |
| `reasons` | Empty when PASS, otherwise every failed check |
| `provenance.inputBase` | The `% Input:` line embedded in the summary. Must equal `generators_<dataset_id>.txt` |
| `provenance.partial` | True if the summary carries the `% PARTIAL` mark, which always fails |
| `provenance.z0RelDiff` | Summary target color against the generators file target color |
| `provenance.meta.generators_payload_sha256` | SHA-256 of the generators file's numeric payload, which is the band count, target color and generator rows. The header is excluded because it carries a generation timestamp. This is the identity of the problem being solved |
| `provenance.meta.embedded_payload_sha256` | The same hash as echoed by the kernel into the summary. A mismatch means the result came from a different generation of the input |
| `provenance.meta.k1`, `k2`, `norm_policy` | Normalization frame, `white_y100` or `unit_peak`, read from the generators file header |
| `provenance.meta.spacing_nm`, `n_bins` | Wavelength grid |
| `provenance.meta.source_id` | Identity of the code that produced the certificate. It is `git:<commit>` in a checkout and `archive:<hash>` or `tree:<hash>` otherwise. See `tools/source_id.sh` |
| `provenance.meta.validator_sha256` | Hashes of the three validator source files |
| `provenance.meta.validator_working_tree_modified` | Present when the certificate is written in a Git checkout. True if `git status` reports a change to any of the three validator files |
| `provenance.meta.matlab_release`, `gated_at` | MATLAB release and UTC timestamp |
| `integrity.csvRows`, `csvFaces`, `summaryV`, `summaryF` | Shipped CSV row counts against the summary's claims. They must match |
| `integrity.eulerSimplicial` | Whether `F == 2V - 4` holds for the simplicial hull. Recorded, not required |
| `volume.summary`, `recomputed`, `relDiff` | Hull volume recomputed from the shipped vertex bytes against the summary value. `relDiff <= 1e-10` is required. This checks agreement with the stored summary |
| `volume.flat`, `rank`, `dimension` | Present for a flat body or a sensor rank below 6. `rank` is the rank of the six sensors in the generators file. `dimension` is the number of principal axes along which the points' width exceeds 1e-8 of their largest coordinate. `dimension <= rank - 3` is required, and a flat body must have `summary` and `recomputed` both 0 |
| `lp.sampled`, `feasible`, `indeterminate` | Reflectance feasibility of sampled boundary vertices against this dataset's own generators. For each vertex y the check finds a bounded rho in [0,1]^n with G1*rho = z0 and G2*rho = y, and verifies it by recomputing the colors from rho. The sample is deterministic given `seed`, plus the first and last rows and the six coordinate extremes. `indeterminate` must be 0 |
| `lp.infeasible` | Always 0. The check finds witnesses. It does not prove infeasibility |
| `lp.totalVertices`, `allVerticesChecked`, `seed` | Number of rows in the vertices CSV, whether the check covered all of them and the seed of the sample |
| `lp.method`, `scope`, `acceptanceTolerance` | What the feasibility check is and what it does not establish |
| `lp.reflectanceBounds` | The bounds on the reflectance in each band, `[0, 1]` |
| `lp.tau` | The largest acceptance tolerance over the checked vertices |
| `lp.solverSettings` | The four `linprog` settings, in the order they are tried, each with `algorithm`, `constraintTolerance`, `optimalityTolerance` and `equationScale`. A vertex goes on to the next setting only when the previous one gave no reflectance within its tolerance. `equationScale` multiplies the equations before solving, and the residual is checked in the original units |
| `lp.attemptCounts` | One count per solver setting. Entry k is the number of checked vertices that reached setting k, so the first entry equals `lp.sampled` |
| `lp.retriedIdx` | Row indices of the checked vertices that needed more than the first setting |
| `lp.worstResidual`, `worstResidualVertex`, `worstResidualTau` | Largest residual over the checked vertices, the vertex row that attained it and that row's acceptance tolerance. The residual is taken over the target color and the vertex color together |
| `lp.maxResidualRatio`, `maxResidualRatioVertex` | Largest ratio of residual to acceptance tolerance over the checked vertices and the vertex row that attained it. It is at most 1 when every checked vertex has a witness |
| `lp.worstResidualTargetColor`, `worstResidualTargetColorVertex` | Largest residual in the target color under the first mechanism and the vertex row that attained it. The residual is the infinity norm of `G1*rho - z0` |
| `lp.worstResidualVertexColor`, `worstResidualVertexColorVertex` | Largest residual in the vertex color under the second mechanism and the vertex row that attained it. The residual is the infinity norm of `G2*rho - y` |
| `lp.failedIdx` | Row indices without a witness, omitted when there are more than 50 |
| `lp.seconds` | Time the feasibility check took, in seconds |
| `sha256.vertices`, `faces`, `summary`, `generators` | Content hashes of every shipped file. The manifest pins these |
| `tolerances.volume_recompute_rel`, `lp_algorithm`, `lp_acceptance`, `counts_note` | The volume tolerance, the solver settings in words, the acceptance tolerance and the note that vertex and face counts are tolerance-dependent metadata rather than invariants |

### Residual reporting

The feasibility check accepts a vertex when the residual of its witness, taken
over the target color and the vertex color together, is no greater than the
tolerance in `lp.acceptanceTolerance`. That combined residual is what acceptance
uses, and it is reported as `lp.worstResidual`.

The same residual is also reported split into its two halves, as
`lp.worstResidualTargetColor` and `lp.worstResidualVertexColor`. The split tells
you which half of the constraint is harder to satisfy for a given dataset.
The split is recorded for reporting only. It does not enter the acceptance
decision, and the tolerance and solver settings are the same with or without it.

## Collection certificate

Path: `gate_reports/collection_certificate.json`

Schema id: `mmb-collection-certificate/1`. Written by
`src/validateCollection.m`, which also writes
`gate_reports/manifest_gated.txt` listing only passing datasets with their
volumes, counts and content hashes.

| Field | Meaning |
|---|---|
| `schema` | `mmb-collection-certificate/1` |
| `datasets_expected`, `datasets_pass`, `datasets_fail` | Counted against `runs/dataset_ids.txt` |
| `failing_datasets` | Every dataset that is missing or failed |
| `complementarity.pairs_checked`, `worst_rel_asym`, `tol_rel`, `all_pass` | For each pair of reflectance levels p and 100 - p, the hull volumes must agree to `tol_rel`, default 1e-9. The two runs are independent and the bodies are exactly point-symmetric. Agreement does not rule out errors shared by both runs. Neither this check nor reflectance feasibility detects all missing vertices |
| `dataset_ids_file_sha256` | Hash of the collection definition used |
| `result` | `PASS` only if every dataset passes and complementarity holds |
| `gated_at` | UTC time the certificate was written |
| `pairs` | The pair-by-pair record. Each entry names the two datasets in `dataset_lo` and `dataset_hi`. `rel_asym` is their volume difference relative to the larger volume. `agree_digits` is -log10 of `rel_asym`, at most 17. `pass` says whether `rel_asym` is within `tol_rel` |

## The certificates in the data archive

Every dataset in the data archive ships a certificate. They declare
`mmb-gate-report/1` and use the field names above, with these differences
from `mmb-dataset-report/2`:

- Their `lp` holds only `method`, `sampled`, `feasible`, `indeterminate`,
  `infeasible`, `failedIdx`, `worstResidual`, `tau` and `seconds`. `lp.tau`
  holds the acceptance tolerance, and `lp.method` reads `phase1-residual`
  for a sampled check.
- `provenance.meta` has no `validator_sha256` or
  `validator_working_tree_modified`, and `tolerances` has no
  `lp_acceptance`.

`provenance.meta.source_id` in these certificates identifies the source that
ran the checks at the time. Those identifiers need not resolve to commits in
the public repository.

The two datasets checked at every boundary vertex,
`1931_2deg_D65_A_1nm_refl50` and `cfb_10deg_D65_FL11_1nm_refl10`, are the
exception. Their certificates declare `mmb-dataset-report/2` and were
written by `src/validateDataset.m` of this release with `Sample=Inf`. Their
`provenance.meta.source_id` names the release commit, and their
`provenance.meta.validator_sha256` holds the hashes of the validator files
in `src/`.

## Reading a pass result

PASS means the listed checks succeeded within their recorded tolerances.
It does not establish completeness of enumeration or vertex extremality.
The manifest is generated from passing certificates.

`validateAllMMBTest` checks geometric consistency of completed results.
It does not test reflectance feasibility against the generators. Use
`validateDataset` or `validateCollection` for those checks.
