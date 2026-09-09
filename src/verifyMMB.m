function report = verifyMMB(resultsDir, genFile, options)
% VERIFYMMB  Validate an MMB against its generators file.
%
%   report = verifyMMB(resultsDir, genFile) checks:
%     Provenance: the summary names genFile, has no PARTIAL marker and
%                 records the same target color.
%     Integrity:  CSV dimensions, finite coordinates and face indices.
%     Volume:     convhulln volume agrees with the summary within VolTol.
%                 A flat body (summary line "Flat body:") must have volume
%                 0, no faces and points spanning at most 2 dimensions.
%                 At sensor rank r (of the generators) the points may span
%                 at most r-3 dimensions, and r below 6 requires a flat body.
%     Reflectance feasibility: sampled vertices have a generating spectrum
%                 rho in [0,1] satisfying G1*rho = z0 and G2*rho = y within
%                 the tolerance. The returned spectrum is checked directly.
%
%   A missing reflectance witness fails validation. This check does not
%   establish whether each point is extreme or whether all vertices are listed.
%
%   INPUTS:
%       resultsDir      directory containing mmb_<datasetId>_{vertices.csv,
%                       faces.csv,summary.txt}
%       genFile   path to generators_<datasetId>.txt (the defining input)
%
%   OPTIONAL (Name-Value):
%       Sample    number of boundary vertices to LP-verify (default 1024,
%                 Inf = all). Sampling is deterministic given Seed.
%       Seed      RNG seed for the sample (default 1)
%       VolTol    relative tolerance for volume recompute (default 1e-10)
%       Verbose   print progress (default true)
%
%   OUTPUT: report struct with .pass (logical), .reasons (string array) and
%   per-check substructs (provenance, integrity, volume, lp, sha).
%
%   The lp substruct records the worst residual over the checked vertices as
%   lp.worstResidual, and also splits it. lp.worstResidualTargetColor is the
%   largest residual in the target color under the first mechanism, and
%   lp.worstResidualVertexColor is the largest residual in the vertex color
%   under the second. Each has a companion field naming the vertex row that
%   attained it. The split is recorded for reporting and takes no part in
%   acceptance.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    resultsDir (1,1) string
    genFile (1,1) string
    options.Sample (1,1) double = 1024
    options.Seed (1,1) double = 1
    options.VolTol (1,1) double = 1e-10
    options.Verbose (1,1) logical = true
end

report = struct();
report.pass = false;
report.reasons = strings(0,1);

    function flag(msg, varargin)
        report.reasons(end+1) = sprintf(msg, varargin{:});
    end

% Read the dataset name from the generators filename.
[~, cdBase, cdExt] = fileparts(genFile);
cdName = string(cdBase) + string(cdExt);
datasetId = extractBetween(cdName, "generators_", ".txt");
assert(~isempty(datasetId), "verifyMMB:badColordataName", ...
    "generators file must be named generators_<datasetId>.txt, got %s", cdName);
datasetId = datasetId(1);
report.dataset_id = datasetId;

vPath = fullfile(resultsDir, "mmb_" + datasetId + "_vertices.csv");
fPath = fullfile(resultsDir, "mmb_" + datasetId + "_faces.csv");
sPath = fullfile(resultsDir, "mmb_" + datasetId + "_summary.txt");
for p = [vPath, fPath, sPath, string(genFile)]
    if ~isfile(p)
        flag("missing file: %s", p);
    end
end
if ~isempty(report.reasons)
    return
end

% Load the defining input. The band count is checked inside
% readGenerators and is not needed here.
[~, z0, G1, G2] = readGenerators(genFile);

% Load results.
V = readmatrix(vPath, FileType="text");
F = readmatrix(fPath, FileType="text");
summaryTxt = string(fileread(sPath));

% Provenance.
prov = struct();
tok = regexp(summaryTxt, "% Input: (\S+)", "tokens", "once");
if isempty(tok)
    prov.inputBase = "";
    flag("summary has no '%% Input:' line");
else
    [~, ib, ie] = fileparts(tok(1));
    prov.inputBase = string(ib) + string(ie);
    if prov.inputBase ~= cdName
        flag("PROVENANCE: summary Input is '%s', not '%s'", ...
            prov.inputBase, cdName);
    end
end
prov.partial = contains(summaryTxt, "% PARTIAL");
if prov.partial
    flag("summary contains a %% PARTIAL marker (incomplete chunk set)");
end
% The summary records z0 to six decimal places.
tok = regexp(summaryTxt, "% z0 = \[([0-9eE.+\-]+), ([0-9eE.+\-]+), ([0-9eE.+\-]+)\]", "tokens", "once");
if ~isempty(tok)
    z0hdr = str2double(tok(:));
    prov.z0RelDiff = max(abs(z0hdr - z0) ./ max(abs(z0), 1));
    if prov.z0RelDiff > 1e-5
        flag("PROVENANCE: summary z0 [%g %g %g] != generators file z0 [%g %g %g]", ...
            z0hdr, z0);
    end
else
    prov.z0RelDiff = NaN;
end
report.provenance = prov;

% Integrity.
integ = struct();
integ.csvRows = size(V, 1);
integ.csvFaces = size(F, 1);
tok = regexp(summaryTxt, "Boundary vertices:\s*(\d+)", "tokens", "once");
integ.summaryV = str2double(tok(1));
tok = regexp(summaryTxt, "Boundary faces:\s*(\d+)", "tokens", "once");
integ.summaryF = str2double(tok(1));
if integ.csvRows ~= integ.summaryV
    flag("INTEGRITY: vertices CSV has %d rows, summary says %d", integ.csvRows, integ.summaryV);
end
if integ.csvFaces ~= integ.summaryF
    flag("INTEGRITY: faces CSV has %d rows, summary says %d", integ.csvFaces, integ.summaryF);
end
if any(~isfinite(V(:)))
    flag("INTEGRITY: vertices CSV contains non-finite values");
end
if ~isempty(F) && (min(F(:)) < 1 || max(F(:)) > size(V, 1))
    flag("INTEGRITY: face indices out of range [1, %d]", size(V, 1));
end
flat = ~isempty(regexp(summaryTxt, "(^|\n)Flat body:", "once"));
if flat && integ.csvFaces ~= 0
    flag("INTEGRITY: flat body has %d faces. It must have none", integ.csvFaces);
end
integ.eulerSimplicial = (integ.csvFaces == 2 * integ.csvRows - 4);
report.integrity = integ;

% Recompute volume from the vertices CSV.
volr = struct();
tok = regexp(summaryTxt, "Hull volume:\s*([0-9eE.+\-]+)", "tokens", "once");
volr.summary = str2double(tok(1));
volr.recomputed = NaN;
volr.relDiff = NaN;
sensorRank = rank([G1; G2]);
if flat || sensorRank < 6
    % Sensors of rank r put the body in an (r-3)-D flat. A flat body's
    % volume is 0 when its points span at most 2 dimensions
    volr.flat = flat;
    volr.rank = sensorRank;
    volr.dimension = pointDimension(V);
    if volr.dimension > sensorRank - 3
        flag("VOLUME: points span %d dimensions. Sensor rank %d allows at most %d", ...
            volr.dimension, sensorRank, sensorRank - 3);
    end
end
if flat
    if volr.dimension <= 2
        volr.recomputed = 0;
    end
    volr.relDiff = abs(volr.recomputed - volr.summary);
    if ~(volr.summary == 0 && volr.recomputed == 0)
        flag("VOLUME: flat body with summary volume %.15e and points spanning %d dimensions. Both must give volume 0", ...
            volr.summary, volr.dimension);
    end
elseif sensorRank < 6
    flag("VOLUME: sensor rank %d gives a flat body, but the summary has no 'Flat body:' line", sensorRank);
elseif size(V, 1) >= 4 && all(isfinite(V(:)))
    [~, volr.recomputed] = convhulln(V);
    volr.relDiff = abs(volr.recomputed - volr.summary) / max(abs(volr.summary), realmin);
    if volr.relDiff > options.VolTol
        flag("VOLUME: recomputed %.15e vs summary %.15e (rel %.3e > %.1e)", ...
            volr.recomputed, volr.summary, volr.relDiff, options.VolTol);
    end
else
    flag("VOLUME: cannot recompute (degenerate or non-finite vertex set)");
end
report.volume = volr;

% Check reflectance feasibility using the generators.
% Minimize t subject to -t <= [G1;G2]*rho - [z0;y] <= t, rho in [0,1]^n.
% Check the bounded reflectance by recomputing its colors. Retry when its
% residual exceeds the tolerance. If no witness is found, record the vertex
% as indeterminate.
lp = struct();
nV = size(V, 1);
K = min(options.Sample, nV);
rng(options.Seed, "twister");
idx = randperm(nV, K);
% Include the first and last rows and the six coordinate extrema.
[~, iminx] = min(V(:,1)); [~, imaxx] = max(V(:,1));
[~, iminy] = min(V(:,2)); [~, imaxy] = max(V(:,2));
[~, iminz] = min(V(:,3)); [~, imaxz] = max(V(:,3));
idx = unique([idx, 1, nV, iminx, imaxx, iminy, imaxy, iminz, imaxz]);

Aeq = [G1; G2];             % 6 x n
lp.method = "phase1-direct-witness/2";
lp.scope = "Bounded reflectance feasibility, not a proof of extremality or enumeration completeness";
lp.sampled = numel(idx);
lp.totalVertices = nV;
lp.allVerticesChecked = (numel(idx) == nV);
lp.seed = options.Seed;
lp.infeasible = 0;  % This check does not produce a proof of infeasibility.
lp.indeterminate = 0;
lp.failedIdx = [];
lp.retriedIdx = [];
lp.attemptCounts = zeros(1, 4);
lp.worstResidual = 0;
lp.worstResidualVertex = NaN;
lp.worstResidualTau = NaN;
lp.worstResidualTargetColor = 0;
lp.worstResidualTargetColorVertex = NaN;
lp.worstResidualVertexColor = 0;
lp.worstResidualVertexColorVertex = NaN;
lp.maxResidualRatio = 0;
lp.maxResidualRatioVertex = NaN;
lp.tau = NaN;
lp.acceptanceTolerance = "1e-8 * max(1, norm([z0; vertex], Inf))";
lp.reflectanceBounds = [0, 1];
t0 = tic;
for ii = 1:numel(idx)
    beq = [z0; V(idx(ii), :)'];
    [rhoWitness, check] = findReflectanceWitness(Aeq, beq);
    % Split the witness residual into the part that reproduces the target
    % color under the first mechanism and the part that reproduces the
    % vertex color under the second. This is recording only. Acceptance
    % still uses check.residual, the infinity norm over both parts
    % together, against the unchanged tolerance in findReflectanceWitness.
    if ~isempty(rhoWitness)
        resTargetColor = norm(G1*rhoWitness - z0, Inf);
        resVertexColor = norm(G2*rhoWitness - V(idx(ii), :)', Inf);
        if resTargetColor > lp.worstResidualTargetColor
            lp.worstResidualTargetColor = resTargetColor;
            lp.worstResidualTargetColorVertex = idx(ii);
        end
        if resVertexColor > lp.worstResidualVertexColor
            lp.worstResidualVertexColor = resVertexColor;
            lp.worstResidualVertexColorVertex = idx(ii);
        end
    end
    lp.tau = max(lp.tau, check.tau, "omitnan");
    lp.solverSettings = check.solverSettings;
    if check.attempts > 0
        lp.attemptCounts(1:check.attempts) = lp.attemptCounts(1:check.attempts) + 1;
    end
    if check.attempts > 1
        lp.retriedIdx(end+1) = idx(ii);
    end
    if check.residual > lp.worstResidual
        lp.worstResidual = check.residual;
        lp.worstResidualVertex = idx(ii);
        lp.worstResidualTau = check.tau;
    end
    if check.residual / check.tau > lp.maxResidualRatio
        lp.maxResidualRatio = check.residual / check.tau;
        lp.maxResidualRatioVertex = idx(ii);
    end
    if ~check.accepted
        lp.indeterminate = lp.indeterminate + 1;
        lp.failedIdx(end+1) = idx(ii);
        if options.Verbose && lp.indeterminate <= 3
            fprintf("  UNRESOLVED: vertex row %d, best direct residual %.3e, tau %.3e\n", ...
                idx(ii), check.residual, check.tau);
        end
    end
    if options.Verbose && mod(ii, 5000) == 0
        fprintf("  Checked %d/%d vertices, %d unresolved (%.1fs)\n", ...
            ii, lp.sampled, lp.indeterminate, toc(t0));
    end
end
lp.seconds = toc(t0);
lp.feasible = lp.sampled - lp.indeterminate;
if lp.indeterminate > 0
    flag("FEASIBILITY: no bounded reflectance found within tolerance for %d of %d checked vertices after solver retries. They are indeterminate", ...
        lp.indeterminate, lp.sampled);
end
report.lp = lp;

% Hash the data files.
report.sha = struct("vertices", fileSha256(vPath), "faces", fileSha256(fPath), ...
    "summary", fileSha256(sPath), "generators", fileSha256(string(genFile)));

report.pass = isempty(report.reasons);
if options.Verbose
    if report.pass
        fprintf("verifyMMB PASS %s: %d/%d LP-feasible, vol rel %.2e, provenance OK (%.1fs)\n", ...
            datasetId, lp.feasible, lp.sampled, volr.relDiff, lp.seconds);
    else
        fprintf("verifyMMB FAIL %s:\n", datasetId);
        fprintf("  - %s\n", report.reasons);
    end
end
end


function d = pointDimension(points)
% POINTDIMENSION  Principal axes along which the points' width exceeds 1e-8
%   of their largest coordinate, the flat-body rule of hullMMB
    centered = points - mean(points, 1);
    [~, ~, principal] = svd(centered, "econ");
    along = centered * principal;
    widths = max(along, [], 1) - min(along, [], 1);
    d = sum(widths > 1e-8 * max(abs(points), [], "all"));
end


function [n, z0, G1, G2] = readGenerators(cdFile)
% READGENERATORS  Parse a generators_<datasetId>.txt into n, z0 (3x1) and G1/G2 (3xn)
    fid = fopen(cdFile, 'r');
    assert(fid > 0, "verifyMMB:cannotOpen", "Cannot open %s", cdFile);
    cleanupObj = onCleanup(@() fclose(fid));
    line = fgetl(fid);
    while ischar(line) && (isempty(strtrim(line)) || line(1) == '%')
        line = fgetl(fid);
    end
    n = sscanf(line, "%d");
    z0line = fgetl(fid);
    z0 = sscanf(z0line, "%f");
    assert(numel(z0) == 3, "verifyMMB:badColordata", "z0 line malformed in %s", cdFile);
    raw = textscan(fid, "%f%f%f%f%f%f%f");
    G1 = [raw{2}, raw{3}, raw{4}]';   % 3 x n
    G2 = [raw{5}, raw{6}, raw{7}]';   % 3 x n
    assert(size(G1, 2) == n && size(G2, 2) == n, "verifyMMB:badColordata", ...
        "generator rows (%d) != header n (%d) in %s", size(G1, 2), n, cdFile);
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
