function report = validateDataset(runDir, options)
% VALIDATEDATASET  Validate one MMB and write its certificate.
%
%   report = validateDataset(runDir) checks the generators and result files
%   in runDir using verifyMMB. It records the input and source-file hashes,
%   normalization, MATLAB release, tolerances and validation results in
%   results/mmb_<dataset_id>_gate.json. The dataset_id is the name of runDir.
%
%   OPTIONAL (Name-Value):
%       Sample    boundary vertices to check by LP (default 1024)
%       Seed      sampling seed (default 1)
%       Force     validate even if a PASS certificate exists (default false)
%       Verbose   default true
%
%   readValidationReport reads a certificate back, and accepts both field
%   layouts described there.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    runDir (1,1) string
    options.Sample (1,1) double = 1024
    options.Seed (1,1) double = 1
    options.Force (1,1) logical = false
    options.Verbose (1,1) logical = true
end

datasetId = string(regexp(char(runDir), '[^/\\]+[/\\]?$', 'match', 'once'));
datasetId = erase(datasetId, ["/", "\"]);
cdFile = fullfile(runDir, "generators_" + datasetId + ".txt");
assert(isfile(cdFile), "validateDataset:noGenerators", ...
    "no generators file for dataset_id '%s' at %s", datasetId, cdFile);
resultsDir = fullfile(runDir, "results");
certPath = fullfile(resultsDir, "mmb_" + datasetId + "_gate.json");

% Reuse a passing certificate only when its data-file hashes still match.
if ~options.Force && isfile(certPath)
    prev = jsondecode(fileread(certPath));
    if isfield(prev, "result") && string(prev.result) == "PASS" && isfield(prev, "sha256")
        vP = fullfile(resultsDir, "mmb_" + datasetId + "_vertices.csv");
        fP = fullfile(resultsDir, "mmb_" + datasetId + "_faces.csv");
        sP = fullfile(resultsDir, "mmb_" + datasetId + "_summary.txt");
        fresh = isfile(vP) && isfile(fP) && isfile(sP) && isfile(cdFile) && ...
            string(prev.sha256.vertices) == fileSha256(vP) && ...
            string(prev.sha256.faces) == fileSha256(fP) && ...
            string(prev.sha256.summary) == fileSha256(sP) && ...
            string(prev.sha256.generators) == fileSha256(cdFile);
        if fresh
            if options.Verbose
                fprintf("validateDataset SKIP %s: PASS certificate matches current result files\n", datasetId);
            end
            report = prev;
            return
        end
        if options.Verbose
            fprintf("validateDataset %s: data files changed, validating again\n", datasetId);
        end
    end
end

v = verifyMMB(resultsDir, cdFile, Sample=options.Sample, Seed=options.Seed, ...
    Verbose=options.Verbose);

% Provenance metadata.
cdTxt = string(fileread(cdFile));
meta = struct();
meta.generators_payload_sha256 = payloadSha256(cdFile);
tok = regexp(cdTxt, "k1=([0-9eE.+\-]+), k2=([0-9eE.+\-]+) \(([a-z_0-9]+)", "tokens", "once");
if ~isempty(tok)
    meta.k1 = str2double(tok(1));
    meta.k2 = str2double(tok(2));
    meta.norm_policy = tok(3);
else
    meta.k1 = NaN; meta.k2 = NaN; meta.norm_policy = "unknown";
end
tok = regexp(cdTxt, "% Spacing: (\d+) nm \((\d+) bins\)", "tokens", "once");
if ~isempty(tok)
    meta.spacing_nm = str2double(tok(1));
    meta.n_bins = str2double(tok(2));
end
% Compare the generator hash recorded by the kernel with the current input.
sumTxt = string(fileread(fullfile(resultsDir, "mmb_" + datasetId + "_summary.txt")));
tok = regexp(sumTxt, "% payload_sha256=([0-9a-f]{64})", "tokens", "once");
if isempty(tok)
    meta.embedded_payload_sha256 = "not recorded";
else
    meta.embedded_payload_sha256 = tok(1);
    if tok(1) ~= meta.generators_payload_sha256
        v.pass = false;
        v.reasons(end+1) = sprintf( ...
            "GENERATION MISMATCH: result was computed from generators file payload %s..., current generators file is %s...", ...
            extractBefore(tok(1), 13), extractBefore(meta.generators_payload_sha256, 13));
    end
end

% Identify the code that produced this certificate. The script
% tools/source_id.sh reports the Git commit in a checkout and the packaged
% source record in an extracted release archive, so a certificate is
% traceable either way.
repoRoot = fileparts(fileparts(mfilename("fullpath")));
[st, srcId] = system("bash """ + fullfile(repoRoot, "tools", "source_id.sh") + """ 2>/dev/null");
if st == 0 && strlength(strtrim(string(srcId))) > 0
    meta.source_id = strtrim(string(srcId));
else
    meta.source_id = "unknown";
end
% Record source-file hashes to identify local edits as well as the source id.
validatorDir = string(fileparts(mfilename("fullpath")));
validatorFiles = ["verifyMMB.m", "findReflectanceWitness.m", "validateDataset.m"];
meta.validator_sha256 = struct();
for validatorFile = validatorFiles
    [~, field] = fileparts(validatorFile);
    meta.validator_sha256.(field) = fileSha256(fullfile(validatorDir, validatorFile));
end
[statusCode, validatorStatus] = system("git -C """ + repoRoot + ...
    """ status --porcelain -- src/verifyMMB.m src/findReflectanceWitness.m src/validateDataset.m 2>/dev/null");
if statusCode == 0
    meta.validator_working_tree_modified = (strlength(strtrim(string(validatorStatus))) > 0);
end
meta.matlab_release = string(version("-release"));
meta.gated_at = string(datetime("now", "TimeZone", "UTC", ...
    "Format", "yyyy-MM-dd'T'HH:mm:ss'Z'"));

% Assemble the certificate.
report = struct();
report.schema = "mmb-dataset-report/2";
report.dataset_id = datasetId;
report.result = ternary(v.pass, "PASS", "FAIL");
report.reasons = v.reasons;
report.provenance = v.provenance;
report.provenance.meta = meta;
report.integrity = v.integrity;
report.volume = v.volume;
report.lp = rmfieldIf(v.lp, "failedIdx", numel(v.lp.failedIdx) > 50);
report.sha256 = v.sha;
report.tolerances = struct( ...
    "volume_recompute_rel", 1e-10, ...
    "lp_algorithm", "dual-simplex with tighter, interior-point and rescaled retries", ...
    "lp_acceptance", v.lp.acceptanceTolerance, ...
    "counts_note", "vertex/face counts are tolerance-dependent metadata, not invariants; see summary tolerance tags");

% Write atomically.
if ~isfolder(resultsDir), mkdir(resultsDir); end
tmp = certPath + ".tmp";
fid = fopen(tmp, "w");
assert(fid > 0, "validateDataset:cannotWrite", "cannot write %s", tmp);
fprintf(fid, "%s\n", jsonencode(report, PrettyPrint=true));
fclose(fid);
movefile(tmp, certPath);

if options.Verbose
    fprintf("validateDataset %s: %s -> %s\n", report.result, datasetId, certPath);
end
end


function hex = payloadSha256(cdFile)
% Hash numeric lines, excluding comments and the generation timestamp.
    lines = splitlines(string(fileread(cdFile)));
    keep = lines(~startsWith(strtrim(lines), "%") & strtrim(lines) ~= "");
    payload = join(keep, newline);
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(unicode2native(char(payload), 'UTF-8'));
    hex = lower(string(reshape(dec2hex(typecast(md.digest(), 'uint8'))', 1, [])));
end

function s = rmfieldIf(s, f, cond)
    if cond && isfield(s, f), s = rmfield(s, f); end
end

function hex = fileSha256(path)
% FILESHA256  SHA-256 of a file's bytes (java, no toolbox dependency)
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
