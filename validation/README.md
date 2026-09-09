# Validation evidence

Each subdirectory is named for a dataset_id and contains the records for that
dataset.

The records are bound to content hashes. Each one names the files it covers by
SHA-256, so you can check the evidence against the files you have. You do not
need to resolve a commit or any other revision identifier.

## Contents

`1931_2deg_D65_A_1nm_refl50/` holds a comparison of the released CUDA source
with the source used for the calculation and the GPU timing for that
dataset.

The check of every boundary vertex of this dataset and of
`cfb_10deg_D65_FL11_1nm_refl10` is recorded in their certificates in the
data archive. See `docs/VALIDATION.md` for what each check covers and
`docs/VALIDATION_FORMAT.md` for the certificate fields.
