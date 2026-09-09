# CIE Spectral Data

Source data for exact MMB computation. All files are from the
[CIE Data Tables](https://cie.co.at/data-tables) repository,
published under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

Each CSV file has a companion JSON metadata file following the
[CIEmetaDigitalProduct](https://doi.org/10.25039/CIE.SC.4taqevcd) schema (v4).
The JSON contains DOIs, column headers, interpolation methods, checksums and
provenance. All read at runtime by `prepareGenerators.m`.

## Observers

| File | Description | Wavelengths | Step | DOI |
|------|-------------|-------------|------|-----|
| `CIE_xyz_1931_2deg.csv` | CIE 1931 2-deg standard observer | 360-830 nm | 1 nm | [10.25039/CIE.DS.xvudnb9b](https://doi.org/10.25039/CIE.DS.xvudnb9b) |
| `CIE_xyz_1964_10deg.csv` | CIE 1964 10-deg standard observer | 360-830 nm | 1 nm | [10.25039/CIE.DS.sqksu2n5](https://doi.org/10.25039/CIE.DS.sqksu2n5) |
| `CIE_cfb_stv_2deg.csv` | CIE 170-2 cone-fundamental-based 2-deg | 390-830 nm | 1 nm | [10.25039/CIE.DS.548rw69q](https://doi.org/10.25039/CIE.DS.548rw69q) |
| `CIE_cfb_stv_10deg.csv` | CIE 170-2 cone-fundamental-based 10-deg | 390-830 nm | 1 nm | [10.25039/CIE.DS.dm6qiig7](https://doi.org/10.25039/CIE.DS.dm6qiig7) |
LMS cone fundamentals used by the code (`lms_2deg`, `lms_10deg` observers) are
derived at runtime from the 1nm cfb data via the inverse of the CIE 170-2:2015
transformation matrices (Tables 10.2 and 10.5).

## Illuminants

| File | Contents | Wavelengths | Step | DOI |
|------|----------|-------------|------|-----|
| `CIE_std_illum_A_1nm.csv` | CIE standard illuminant A | 300-830 nm | 1 nm | [10.25039/CIE.DS.8jsxjrsn](https://doi.org/10.25039/CIE.DS.8jsxjrsn) |
| `CIE_std_illum_D50.csv` | CIE standard illuminant D50 | 300-830 nm | 1 nm | [10.25039/CIE.DS.etgmuqt5](https://doi.org/10.25039/CIE.DS.etgmuqt5) |
| `CIE_std_illum_D65.csv` | CIE standard illuminant D65 | 300-830 nm | 1 nm | [10.25039/CIE.DS.hjfjmt59](https://doi.org/10.25039/CIE.DS.hjfjmt59) |
| `CIE_illum_FLs_1nm.csv` | FL1-FL12, FL3.1-FL3.15 (27 fluorescent) | 380-780 nm | 1 nm | [10.25039/CIE.DS.54hy6srn](https://doi.org/10.25039/CIE.DS.54hy6srn) |
| `CIE_illum_LEDs_1nm.csv` | LED-B1 to B5, BH1, RGB1, V1, V2 (9 LED) | 380-780 nm | 1 nm | [10.25039/CIE.DS.dhcw57sd](https://doi.org/10.25039/CIE.DS.dhcw57sd) |

The D65 CSV contains values from 300 to 830 nm. Its companion metadata is
[CIE revision 2](https://files.cie.co.at/Publications-datasets/CIE_std_illum_D65.csv_metadata_v2.json).
That file lists 300 nm for the wavelength column but 360 nm for the
`S_D65(lambda)` spectral-distribution column. The metadata is supplied
unchanged. The CSV wavelengths define the available samples.

Equal energy illuminant E is computed (constant SPD), no file needed.

## JSON Metadata

Each `*_csv_metadata.json` file follows the CIEmetaDigitalProduct schema and
contains:

- **identifier**: DOI for the dataset
- **titles / descriptions**: Human-readable dataset name and abstract
- **datatableInfo.columnHeaders**: Column names, units and quantities
  (used by `prepareGenerators` to find the correct column in multi-column files)
- **datatableInfo.interpolationMethod**: How to interpolate between tabulated values
- **checksums**: MD5 and SHA-256 for data integrity verification
- **rightsList**: License information (CC BY-SA 4.0)

## CSV Format

All files are headerless CSV. The first column is wavelength in nm, and the
remaining columns are spectral values. NaN entries (out-of-range values in
some files) are treated as zero.

## Standards

- ISO/CIE 11664-1:2019 Colorimetry Part 1: CIE standard colorimetric observers
- ISO/CIE 11664-2:2022 Colorimetry Part 2: CIE standard illuminants
- CIE 015:2018 Colorimetry, 4th Edition (fluorescent and LED illuminants)
- CIE 170-1:2006 Fundamental chromaticity diagram Part 1 (LMS cone fundamentals)
- CIE 170-2:2015 Fundamental chromaticity diagram Part 2 (cfb tristimulus values)
