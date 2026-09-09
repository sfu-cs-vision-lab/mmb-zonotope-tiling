function cert = validateCollection(runsRoot, datasetIdsFile, options)
% VALIDATECOLLECTION  Validate the listed datasets and compare paired volumes.
%
% cert = validateCollection(runsRoot, datasetIdsFile) runs validateDataset
% for each listed dataset. It also compares hull volumes for complementary
% reflectance levels p and 100-p within ComplementarityTol.
%
% These checks do not establish completeness of the enumeration.
%
% Outputs under OutDir, default <runsRoot>/../gate_reports:
%   collection_certificate.json   Results of the collection checks.
%   manifest_gated.txt            Passing datasets, volumes and file hashes.
%
% Options:
%   Sample             Per-dataset LP sample size. Default: 1024.
%   Force              Revalidate passing datasets. Default: false.
%   ComplementarityTol Relative volume tolerance. Default: 1e-9.
%   OutDir             Report directory.
%   Verbose            Print progress. Default: true.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    runsRoot (1,1) string
    datasetIdsFile (1,1) string
    options.Sample (1,1) double = 1024
    options.Force (1,1) logical = false
    options.ComplementarityTol (1,1) double = 1e-9
    options.OutDir (1,1) string = ""
    options.Verbose (1,1) logical = true
end

datasetIds = readlines(datasetIdsFile);
datasetIds = strtrim(datasetIds(strtrim(datasetIds) ~= ""));
nDatasets = numel(datasetIds);
if options.OutDir == ""
    options.OutDir = fullfile(fileparts(runsRoot), "gate_reports");
end
if ~isfolder(options.OutDir), mkdir(options.OutDir); end

% Per-dataset checks
reports = cell(nDatasets, 1);
for i = 1:nDatasets
    rd = fullfile(runsRoot, datasetIds(i));
    if ~isfolder(rd)
        reports{i} = struct("schema", "mmb-dataset-report/2", "dataset_id", datasetIds(i), ...
            "result", "FAIL", "reasons", "datasetId directory missing: " + rd);
        continue
    end
    try
        reports{i} = validateDataset(rd, Sample=options.Sample, Force=options.Force, ...
            Verbose=options.Verbose);
    catch ME
        reports{i} = struct("schema", "mmb-dataset-report/2", "dataset_id", datasetIds(i), ...
            "result", "FAIL", "reasons", "validateDataset error: " + string(ME.message));
    end
end

passMask = cellfun(@(r) string(r.result) == "PASS", reports);

% Complementarity across (refl p, refl 100-p) pairs of passing datasets
volOf = dictionary(string.empty, double.empty);
for i = 1:nDatasets
    if passMask(i) && isfield(reports{i}, "volume")
        volOf(datasetIds(i)) = reports{i}.volume.recomputed;
    end
end
pairs = struct("dataset_lo", {}, "dataset_hi", {}, "rel_asym", {}, "agree_digits", {}, "pass", {});
for i = 1:nDatasets
    tok = regexp(datasetIds(i), "^(.*_refl)(\d+)$", "tokens", "once");
    if isempty(tok), continue; end
    p = str2double(tok(2));
    if p >= 50, continue; end            % count each pair once, from the low side
    partner = tok(1) + string(100 - p);
    if isKey(volOf, datasetIds(i)) && isKey(volOf, partner)
        v1 = volOf(datasetIds(i)); v2 = volOf(partner);
        rel = abs(v1 - v2) / max(abs(v1), abs(v2));
        if v1 == 0 && v2 == 0
            rel = 0;   % two flat bodies
        end
        pairs(end+1) = struct("dataset_lo", datasetIds(i), "dataset_hi", partner, ...
            "rel_asym", rel, "agree_digits", -log10(max(rel, 1e-17)), ...
            "pass", rel <= options.ComplementarityTol); %#ok<AGROW>
    end
end
compFail = ~isempty(pairs) && any(~[pairs.pass]);

% Collection certificate
cert = struct();
cert.schema = "mmb-collection-certificate/1";
cert.datasets_expected = nDatasets;
cert.datasets_pass = sum(passMask);
cert.datasets_fail = nDatasets - sum(passMask);
cert.failing_datasets = datasetIds(~passMask);
cert.complementarity = struct("pairs_checked", numel(pairs), ...
    "tol_rel", options.ComplementarityTol, ...
    "worst_rel_asym", maxOrNan([pairs.rel_asym]), ...
    "all_pass", ~compFail);
cert.result = ternary(all(passMask) && ~compFail, "PASS", "FAIL");
cert.dataset_ids_file_sha256 = fileSha256(datasetIdsFile);
cert.gated_at = string(datetime("now", "TimeZone", "UTC", ...
    "Format", "yyyy-MM-dd'T'HH:mm:ss'Z'"));
cert.pairs = pairs;

tmp = fullfile(options.OutDir, "collection_certificate.json.tmp");
fid = fopen(tmp, "w");
fprintf(fid, "%s\n", jsonencode(cert, PrettyPrint=true));
fclose(fid);
movefile(tmp, fullfile(options.OutDir, "collection_certificate.json"));

% Manifest of the passing datasets, from validated numbers
tmp = fullfile(options.OutDir, "manifest_gated.txt.tmp");
fid = fopen(tmp, "w");
fprintf(fid, "%% mmb-zonotope-tiling manifest of the passing datasets\n");
fprintf(fid, "%% Each listed dataset passed checks of its input identity,\n");
fprintf(fid, "%% LP feasibility of sampled boundary vertices and\n");
fprintf(fid, "%% volume recomputed from the saved files. See\n");
fprintf(fid, "%% mmb_<datasetId>_gate.json and collection_certificate.json.\n");
fprintf(fid, "%% datasets: %d PASS of %d expected\n\n", sum(passMask), nDatasets);
for i = 1:nDatasets
    if ~passMask(i), continue; end
    r = reports{i};
    fprintf(fid, "=== %s ===\n", r.dataset_id);
    fprintf(fid, "Boundary vertices: %d\n", r.integrity.csvRows);
    fprintf(fid, "Boundary faces:    %d\n", r.integrity.csvFaces);
    fprintf(fid, "Hull volume:       %.15e\n", r.volume.recomputed);
    fprintf(fid, "vertices_sha256:   %s\n", r.sha256.vertices);
    fprintf(fid, "generators_payload_sha256: %s\n", r.provenance.meta.generators_payload_sha256);
    fprintf(fid, "lp_feasible:       %d/%d\n", r.lp.feasible, r.lp.sampled);
end
fclose(fid);
movefile(tmp, fullfile(options.OutDir, "manifest_gated.txt"));

if options.Verbose
    fprintf("\nvalidateCollection %s: %d/%d datasets pass, complementarity worst %.2e over %d pairs\n", ...
        cert.result, cert.datasets_pass, nDatasets, ...
        cert.complementarity.worst_rel_asym, numel(pairs));
    fprintf("Certificate: %s\n", fullfile(options.OutDir, "collection_certificate.json"));
end
end


function m = maxOrNan(x)
    if isempty(x), m = NaN; else, m = max(x); end
end

function hex = fileSha256(path)
    md = java.security.MessageDigest.getInstance('SHA-256');
    fid = fopen(path, 'r');
    cleanupObj = onCleanup(@() fclose(fid));
    while true
        buf = fread(fid, 1048576, '*uint8');
        if isempty(buf), break; end
        md.update(buf);
    end
    hex = lower(string(reshape(dec2hex(typecast(md.digest(), 'uint8'))', 1, [])));
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end
