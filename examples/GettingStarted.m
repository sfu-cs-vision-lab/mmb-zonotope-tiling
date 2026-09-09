%[text] # Explore a supplied MMB in MATLAB
%[text] Run this example in MATLAB on a desktop or laptop with Optimization Toolbox. No GPU or cluster connection is needed.
%[text] It loads the supplied 10 nm metamer mismatch body (MMB), plots its boundary and checks the result against its input. The commands for computing a new MMB on an HPC are shown as text only and are not executed by this example.
here = fileparts(mfilename('fullpath'));
repoRoot = fileparts(here);
addpath(fullfile(repoRoot, 'src'));
fixtures = fullfile(repoRoot, 'tests', 'fixtures');
datasetId = "1931_2deg_D65_A_10nm_refl50";
%%
%[text] ## Vocabulary
%[text] - A **dataset** is one MMB. It is made up of its generators file and its results. \
%[text] - Its **dataset_id** encodes the observer, the two illuminants, the wavelength spacing and the flat-reflectance level. Here that is `1931_2deg_D65_A_10nm_refl50`. It names the CIE 1931 2-degree observer, D65 and A, 10 nm bands and a target color produced by 50% flat reflectance under D65. \
%[text] - The **collection** is the full set listed in `runs/dataset_ids.txt`. \
%%
%[text] ## The input
%[text] `prepareGenerators` reads the CIE tables and writes one generators file per dataset. Lines starting with `%` are metadata. The numeric section holds the band count, the target color under the first illuminant and then one row per band. Each band row holds the wavelength, three weights for the first mechanism and three for the second.
generatorsFile = fullfile(fixtures, "generators_" + datasetId + ".txt");
header = splitlines(string(fileread(generatorsFile)));
disp(header(startsWith(header, "% Spacing") | startsWith(header, "% z0") | startsWith(header, "% Normalization")))
%[text] The header also carries the SHA-256 of the numeric payload. That hash is the identity of the problem being solved. The GPU kernel copies it into its output, so every later check can confirm that a result came from this exact input.
disp(header(startsWith(header, "% payload_sha256")))
%%
%[text] ## Computing a new MMB on an HPC (commands to run separately)
%[text] One command generates the input, submits the work and builds the hull. Configure your site in `config/cluster.sh` first.
%[text] ```
%[text] source tools/env.sh
%[text] make -C cuda NVCC_ARCH="$MMB_GPU_ARCH"
%[text] bash mmb_run.sh runs/runs_validate_10nm.m
%[text] bash mmb_run.sh --status
%[text] ```
%[text] Re-running the same command is the recovery path. Finished datasets are skipped, running ones are left alone and missing chunks or failed hulls are resubmitted. `--dry-run` shows the routing without submitting anything.
%%
%[text] ## The results
%[text] Results are plain text. The vertices file is N-by-3 coordinates. The faces file is M-by-3 one-based vertex indices, one triangle per row.
verts = readmatrix(fullfile(fixtures, "mmb_" + datasetId + "_vertices.csv"), FileType="text");
faces = readmatrix(fullfile(fixtures, "mmb_" + datasetId + "_faces.csv"), FileType="text");
fprintf("%d vertices, %d triangular faces\n", size(verts, 1), size(faces, 1));
%%
%[text] ## Plotting the boundary
trisurf(faces, verts(:,1), verts(:,2), verts(:,3), ...
    FaceColor=[0.3 0.6 1], FaceAlpha=0.6, EdgeAlpha=0.1);
axis equal
grid on
xlabel("X"); ylabel("Y"); zlabel("Z");
title("MMB: D65 to A, 1931 2-degree observer, 10 nm");
view(135, 25);
%%
%[text] ## Reading the summary
%[text] The summary records counts, the hull volume, shape measurements, the tolerances used and the provenance of the run.
summaryText = string(fileread(fullfile(fixtures, "mmb_" + datasetId + "_summary.txt")));
volume = sscanf(extractAfter(summaryText, "Hull volume:"), "%f", 1);
fprintf("hull volume: %.15e\n", volume);
%[text] The volume is expressed in the normalized frame named in the generators file header. Compare volumes only between datasets that share a normalization. Vertex and face counts depend on the deduplication tolerance and are metadata rather than invariants. Validation compares the recomputed volume with the summary.
%%
%[text] ## Checking a result
%[text] `verifyMMB` checks the results against their input. It checks provenance and file consistency, recomputes the hull volume from the bytes on disk and looks for a bounded reflectance that reproduces both colors for a sample of boundary vertices.
%[text] The fixtures are laid out here the way a dataset directory is laid out on a cluster, so the checks can run on them. The directory is named after the dataset_id, which is where `validateDataset` reads it from.
scratch = fullfile(tempdir, "mmb_getting_started");
work = fullfile(scratch, datasetId);
resultsDir = fullfile(work, "results");
if ~isfolder(resultsDir)
    mkdir(resultsDir);
end
copyfile(generatorsFile, work);
for suffix = ["_vertices.csv", "_faces.csv", "_summary.txt"]
    copyfile(fullfile(fixtures, "mmb_" + datasetId + suffix), resultsDir);
end
report = verifyMMB(resultsDir, fullfile(work, "generators_" + datasetId + ".txt"), ...
    Sample=64, Verbose=false);
fprintf("pass: %d   volume agreement: %.2e   witnesses found: %d of %d\n", ...
    report.pass, report.volume.relDiff, report.lp.feasible, report.lp.sampled);
%[text] A failure lists every check that did not hold:
disp(report.reasons)
%%
%[text] ## Writing a certificate
%[text] `validateDataset` runs the same checks over a dataset directory and writes `mmb_<dataset_id>_gate.json` beside the results. The certificate records the hashes of every shipped file, the tolerances used, the MATLAB release and an identifier for the code that produced it.
certificate = validateDataset(work, Sample=64, Verbose=false);
fprintf("%s: %s\n", certificate.dataset_id, certificate.result);
%[text] `readValidationReport` reads a certificate back as a struct, with the same field names the writer used.
stored = readValidationReport(fullfile(resultsDir, "mmb_" + datasetId + "_gate.json"));
fprintf("recomputed volume: %.15e\n", stored.volume.recomputed);
%%
%[text] ## Choosing your own conditions
%[text] A run definition is a short script that calls `prepareGenerators`. Put one in `runs/` and pass it to `mmb_run.sh`.
%[text] ```
%[text] prepareGenerators("1931_2deg", "D65", ["FL11", "LED-B1"], ...
%[text]     Spacing=5, Refl=0.5, DataDir="data");
%[text] ```
%[text] `help prepareGenerators` lists the options, including an explicit target color, a reflectance spectrum instead of a flat level and a custom illuminant supplied as a two-column CSV.
%[text] Cost grows as the sixth power of the band count, so 1 nm datasets are chunked across many GPU jobs. `bash mmb_run.sh --dry-run <run definition>` prints the estimate before anything is submitted.
%[text] Finally, clean up the temporary directory this example created.
rmdir(scratch, "s");
%[text]
%[appendix]{"version":"1.0"}
%---
%[metadata:view]
%   data: {"layout":"inline"}
%---
