function result = compareReference(mode, runsRoot, datasetIdsFile, options)
% COMPAREREFERENCE  Compare inputs or volumes with a stored reference.
%
%   compareReference("inputs", referenceRoot, datasetIdsFile) regenerates
%   each listed input and requires identical numeric payloads. Differences
%   can depend on MATLAB, CPU architecture or numerical libraries.
%   All differences fail this check, including small rounding differences.
%
%   compareReference("volumes", runsRoot, referenceCsv) compares the volumes
%   in passing certificates with reference_volumes.csv. Every dataset must
%   agree within 1e-9 relative tolerance in either direction. Validate the
%   current result files before running this comparison.
%
%   The input comparison uses the CIE tables in data/. Set DataDir to use
%   another location. Set Verbose=false to suppress progress messages.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    mode (1,1) string
    runsRoot (1,1) string
    datasetIdsFile (1,1) string
    options.DataDir (1,1) string = ""
    options.Verbose (1,1) logical = true
end

repoRoot = fileparts(fileparts(mfilename("fullpath")));
if options.DataDir == ""
    options.DataDir = fullfile(repoRoot, "data");
end
switch lower(mode)
    case "inputs"
        result = compareInputs(runsRoot, datasetIdsFile, options);
    case "volumes"
        result = compareVolumes(runsRoot, datasetIdsFile, options);
    otherwise
        error("compareReference:badMode", "mode must be 'inputs' or 'volumes'");
end
end


function r = compareInputs(runsRoot, datasetIdsFile, options)
    datasetIds = readlines(datasetIdsFile);
    datasetIds = strtrim(datasetIds(strtrim(datasetIds) ~= ""));
    tmp = fullfile(tempdir, "mmb_reference_" + string(feature('getpid')));
    if isfolder(tmp), rmdir(tmp, 's'); end
    mkdir(tmp);
    cleanupObj = onCleanup(@() rmdir(tmp, 's'));

    r.mode = "inputs"; r.checked = 0; r.bitIdentical = 0;
    r.mismatched = strings(0,1); r.missingStored = strings(0,1); r.regenFailed = strings(0,1);
    r.lsbOnly = strings(0,1);      % relative difference at most 1e-12
    r.divergent = strings(0,1);    % relative difference greater than 1e-12
    r.worstMismatchRel = 0;
    for i = 1:numel(datasetIds)
        datasetId = datasetIds(i);
        stored = fullfile(runsRoot, datasetId, "generators_" + datasetId + ".txt");
        if ~isfile(stored)
            r.missingStored(end+1) = datasetId;
            continue
        end
        % info is read by the evalc call below, which the analyzer
        % cannot see.
        info = parseDatasetId(datasetId); %#ok<NASGU>
        outDir = fullfile(tmp, datasetId);
        mkdir(outDir);
        try
            evalc("prepareGenerators(info.observer, info.illum1, info.illum2, " + ...
                "Spacing=info.spacing, Refl=info.refl, " + ...
                "DataDir=options.DataDir, OutputDir=outDir);");
        catch ME
            r.regenFailed(end+1) = datasetId + " :: " + string(ME.message);
            continue
        end
        regen = fullfile(outDir, "generators_" + datasetId + ".txt");
        r.checked = r.checked + 1;
        if payload(regen) == payload(stored)
            r.bitIdentical = r.bitIdentical + 1;
        else
            r.mismatched(end+1) = datasetId;
            % Report the size of a mismatch to help investigate it.
            A = readmatrix(regen, FileType="text", CommentStyle="%", NumHeaderLines=2);
            Bm = readmatrix(stored, FileType="text", CommentStyle="%", NumHeaderLines=2);
            if isequal(size(A), size(Bm))
                relDiff = max(abs(A(:) - Bm(:)) ./ max(abs(Bm(:)), 1e-300));
            else
                relDiff = Inf;
            end
            r.worstMismatchRel = max(r.worstMismatchRel, relDiff);
            if relDiff <= 1e-12
                r.lsbOnly(end+1) = datasetId;
            else
                r.divergent(end+1) = datasetId;
            end
        end
        if options.Verbose && mod(i, 50) == 0
            fprintf("  inputs: %d/%d checked, %d bit-identical\n", i, numel(datasetIds), r.bitIdentical);
        end
    end
    % A passing input comparison requires identical payloads for every dataset.
    r.pass = (r.checked > 0) && (r.bitIdentical == r.checked) && ...
        isempty(r.regenFailed) && isempty(r.missingStored);
    if options.Verbose
        fprintf("inputs %s: %d/%d generators file payloads bit-identical (LSB-only: %d, DIVERGENT: %d, worst rel %.2e, missing: %d, regen failed: %d)\n", ...
            ternary(r.pass, "PASS", "FAIL"), r.bitIdentical, r.checked, ...
            numel(r.lsbOnly), numel(r.divergent), r.worstMismatchRel, ...
            numel(r.missingStored), numel(r.regenFailed));
        if ~isempty(r.divergent)
            fprintf("  DIVERGENT: %s\n", r.divergent);
        end
    end
end


function r = compareVolumes(runsRoot, referenceCsv, options)
% Compare every recorded volume with the reference in both directions.
    T = readtable(referenceCsv, TextType="string", Delimiter=",");
    assert(all(ismember(["dataset_id", "ref_volume"], string(T.Properties.VariableNames))), ...
        "compareReference:badReference", "Reference requires dataset_id and ref_volume columns.");
    assert(height(T) > 0 && numel(unique(T.dataset_id)) == height(T) && ...
        all(isfinite(T.ref_volume) & T.ref_volume > 0), ...
        "compareReference:badReference", "Reference must contain unique datasets and positive finite volumes.");
    r.mode = "volumes";
    r.expected = height(T);
    r.checked = 0;
    r.matched = 0;
    r.tolerance = 1e-9;
    r.worstRel = 0;
    r.missing = strings(0,1);
    r.failures = strings(0,1);
    for i = 1:height(T)
        datasetId = T.dataset_id(i);
        reportFile = fullfile(runsRoot, datasetId, "results", "mmb_" + datasetId + "_gate.json");
        if ~isfile(reportFile)
            r.missing(end+1) = datasetId;
            continue
        end
        g = readValidationReport(reportFile);
        if ~isfield(g, "result") || string(g.result) ~= "PASS" || ...
                ~isfield(g, "dataset_id") || string(g.dataset_id) ~= datasetId
            r.failures(end+1) = datasetId + ": a passing certificate for this dataset is required";
            continue
        end
        newVol = g.volume.recomputed;
        r.checked = r.checked + 1;
        if ~isscalar(newVol) || ~isfinite(newVol) || newVol <= 0
            r.failures(end+1) = datasetId + ": recorded volume must be positive and finite";
            continue
        end
        rel = abs(newVol - T.ref_volume(i)) / T.ref_volume(i);
        r.worstRel = max(r.worstRel, rel);
        if rel <= r.tolerance
            r.matched = r.matched + 1;
        else
            r.failures(end+1) = sprintf("%s: relative difference %.3e (result %.15e, reference %.15e)", ...
                datasetId, rel, newVol, T.ref_volume(i));
        end
    end
    r.pass = r.matched == r.expected && isempty(r.missing) && isempty(r.failures);
    if options.Verbose
        fprintf("volumes %s: %d/%d within %.1e relative tolerance, worst %.3e, missing %d\n", ...
            ternary(r.pass, "PASS", "FAIL"), r.matched, r.expected, r.tolerance, r.worstRel, numel(r.missing));
        if ~isempty(r.failures), fprintf("  FAIL %s\n", r.failures); end
        if ~isempty(r.missing), fprintf("  MISSING %s\n", r.missing); end
    end
end


function p = payload(f)
    lines = splitlines(string(fileread(f)));
    p = join(lines(~startsWith(strtrim(lines), "%") & strtrim(lines) ~= ""), newline);
end

function info = parseDatasetId(datasetId)
    obsPat = "(1931_2deg|1964_10deg|cfb_2deg|cfb_10deg|lms_2deg|lms_10deg)";
    tok = regexp(datasetId, "^" + obsPat + "_(.+?)_(.+?)_([0-9]+)nm_refl([0-9]+)$", "tokens", "once");
    assert(~isempty(tok), "compareReference:parse", "cannot parse datasetId '%s'", datasetId);
    info.observer = tok(1); info.illum1 = tok(2); info.illum2 = tok(3);
    info.spacing = str2double(tok(4)); info.refl = str2double(tok(5)) / 100;
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end
