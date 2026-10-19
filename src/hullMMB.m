function mmb = hullMMB(vertexFiles, options)
% HULLMMB  Compute exact MMB boundary from CUDA vertex output
%
%   mmb = hullMMB(vertexFile) reads the text file of y-space vertices
%   produced by the CUDA kernel, verifies its content, deduplicates,
%   computes the convex hull and saves results as CSV and summary files.
%
%   hullMMB(vertexFiles) processes multiple files. If the files are chunk
%   files from a job array (names contain "_chunk"), their vertex data is
%   concatenated and a single hull is computed using the base dataset.
%
% Input checks require matching dataset identifiers and row counts.
% A chunked input must contain every index from 0 to N-1, unless
% AllowPartial=true. Partial results are marked in the summary.
%
%   INPUTS:
%       vertexFiles   Path(s) to MMB vertex file(s) from CUDA kernel
%                     (string or string array)
%
%   OPTIONAL INPUTS (Name-Value arguments):
%       OutputDir      Output directory (string). Default: same as input file.
%       Tol            Deduplication tolerance (double). Default: 1e-8
%                      (uniquetol relative tolerance, scale-invariant).
%       ExpectDatasetID     If set, every input group must belong to this dataset,
%                      anything else is a hard error. Callers that know the
%                      datasetId (the hull job does) must pass this.
%       AllowPartial   Allow hulling an incomplete chunk set (default false).
%                      The summary is then marked "% PARTIAL" and fails the
%                      dataset validation. Use only for inspecting partial results.
%       SelfVerify     Re-read the written CSVs and recompute the hull
%                      volume from the written bytes (default true).
%       Verbose        Print progress messages (logical). Default: true
%
%   OUTPUTS:
%       mmb   Struct (or array of structs) with fields:
%             vertices, faces, nVertices, nFaces, hullVolume, center,
%             datasetId, header, rawVertCount, nNonFinite, trueFaceCount, ...
%
%   Output files (all human-readable text, no .mat):
%       mmb_*_vertices.csv:  Nx3 boundary vertices (%.17g, exact round-trip)
%       mmb_*_faces.csv:     Mx3 triangular faces (1-based indices)
%       mmb_*_summary.txt:   Provenance, counts, volume, content hashes
%
% The coplanar-face count depends on the grouping tolerances. These
% tolerances are recorded with the result. Volume checks compare the
% recomputed hull volume with the value in the summary.
%
% Points whose width along a principal axis is at most 1e-8 of their
% largest coordinate form a flat body, which is a polygon, a segment or a point.
% A flat body has volume 0, its distinct points as vertices and no faces.
% Its summary has a "Flat body:" line and gives the vertex centroid as its
% center. Sensors of rank below 6, as when the two mechanisms share a
% channel, give a flat body.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    vertexFiles (1,:) string
    options.OutputDir (1,1) string = ""
    options.Tol (1,1) double = 1e-8
    options.ExpectDatasetID (1,1) string = ""
    options.AllowPartial (1,1) logical = false
    options.SelfVerify (1,1) logical = true
    options.Verbose (1,1) logical = true
end

% Group files: chunk files with the same base dataset are processed together
[groups, groupDatasetIds] = groupChunkFiles(vertexFiles);
nGroups = numel(groups);

if options.ExpectDatasetID ~= ""
    alien = groupDatasetIds(groupDatasetIds ~= options.ExpectDatasetID);
    if ~isempty(alien)
        error("hullMMB:alienDatasetId", ...
            "Input contains file group(s) for datasetId(s) [%s] but ExpectDatasetID is '%s'. " + ...
            "Each input group must match ExpectDatasetID.", ...
            join(alien, ", "), options.ExpectDatasetID);
    end
end

emptyResult = struct('vertices', [], 'faces', [], 'nVertices', 0, ...
    'nFaces', 0, 'hullVolume', 0, 'volumeCentroid', [], ...
    'vertexCentroid', [], 'center', [], 'surfaceArea', 0, ...
    'sphericity', 0, 'maxDiameter', 0, 'princLengths', [], ...
    'princDirs', [], 'trueFaceCount', 0, 'faceGroupSizes', [], ...
    'datasetId', "", 'header', "", 'rawVertCount', 0, 'nNonFinite', 0, ...
    'partial', false, 'verticesSha256', "", 'facesSha256', "");
mmb = repmat(emptyResult, 1, nGroups);

for gi = 1:nGroups
    groupFiles = groups{gi};
    datasetId = groupDatasetIds(gi);

    if options.Verbose
        if numel(groupFiles) > 1
            fprintf("--- %s (%d chunk files) ---\n", datasetId, numel(groupFiles));
        else
            fprintf("--- %s ---\n", groupFiles(1));
        end
    end

    if options.OutputDir ~= ""
        outDir = options.OutputDir;
    else
        outDir = fileparts(groupFiles(1));
        if outDir == ""
            outDir = ".";
        end
    end
    if ~isfolder(outDir)
        mkdir(outDir);
    end

    % Content verification of every input file
    expectedInput = "generators_" + datasetId + ".txt";
    nFiles = numel(groupFiles);
    hdrs = cell(1, nFiles);
    chunkIdx = nan(1, nFiles);
    nchunksHdr = nan(1, nFiles);
    pts = [];
    for fi = 1:nFiles
        h = parseKernelHeader(groupFiles(fi));
        hdrs{fi} = h;

        if h.inputBase == ""
            error("hullMMB:noProvenance", ...
                "%s has no '%% Input:' line. It is not a kernel output, or its header is truncated.", ...
                groupFiles(fi));
        end
        if h.inputBase ~= expectedInput
            error("hullMMB:wrongProvenance", ...
                "%s claims datasetId '%s' by name but its content is for '%s'. " + ...
                "Refusing: this is the wrong-provenance corruption class.", ...
                groupFiles(fi), datasetId, h.inputBase);
        end
        chunkIdx(fi) = h.chunk;      % NaN when not a chunk file
        nchunksHdr(fi) = h.nchunks;

        chunk = readmatrix(groupFiles(fi), FileType="text", CommentStyle="%");
        if h.vertices >= 0 && size(chunk, 1) ~= h.vertices
            error("hullMMB:truncatedInput", ...
                "%s: %d data rows but header promises vertices=%d. " + ...
                "Refusing: file is truncated or padded.", ...
                groupFiles(fi), size(chunk, 1), h.vertices);
        end
        pts = [pts; chunk]; %#ok<AGROW>
    end

    % Check the complete chunk set even when called without the job scripts.
    isChunkGroup = any(~isnan(chunkIdx));
    partial = false;
    if isChunkGroup
        if any(isnan(chunkIdx))
            error("hullMMB:mixedGroup", ...
                "Group '%s' mixes chunk files and non-chunk files.", datasetId);
        end
        Ns = unique(nchunksHdr);
        if numel(Ns) ~= 1 || isnan(Ns)
            error("hullMMB:inconsistentChunking", ...
                "Group '%s': input files disagree on nchunks [%s].", ...
                datasetId, join(string(nchunksHdr), ","));
        end
        N = Ns;
        idxSorted = sort(chunkIdx);
        expected = 0:(N-1);
        if numel(idxSorted) ~= N || any(idxSorted ~= expected)
            missing = setdiff(expected, chunkIdx);
            msg = sprintf("Group '%s': chunk set incomplete, %d of %d present (missing: %s).", ...
                datasetId, numel(unique(chunkIdx)), N, join(string(missing), ","));
            if options.AllowPartial
                warning("hullMMB:partialSet", ...
                    "%s Proceeding because AllowPartial=true. Output is marked PARTIAL.", msg);
                partial = true;
            else
                error("hullMMB:incompleteChunkSet", ...
                    "%s Cannot build a complete hull from an incomplete input set.", msg);
            end
        end
    end

    header = string(hdrs{1}.headerText);

    nRaw = size(pts, 1);
    if options.Verbose
        fprintf("  Raw vertices:      %d\n", nRaw);
    end

    % Remove and count non-finite coordinates before constructing the hull.
    badRows = any(~isfinite(pts), 2);
    nNonFinite = sum(badRows);
    if nNonFinite > 0
        fprintf("  Removed %d NaN/Inf vertices\n", nNonFinite);
        pts = pts(~badRows, :);
    end

    pts = uniquetol(pts, options.Tol, ByRows=true);
    if options.Verbose
        fprintf("  After dedup:       %d\n", size(pts, 1));
    end

    if isempty(pts)
        error("hullMMB:degenerateInput", "Group '%s': no finite vertices.", datasetId);
    end
    flat = isFlat(pts);

    tic;
    if flat
        vertices = pts;
        faces = zeros(0, 3);
        vol = 0;
    else
        [faces, vol] = convhulln(pts);
        hullIdx = unique(faces(:));
        vertices = pts(hullIdx, :);
        idxMap = zeros(size(pts, 1), 1);
        idxMap(hullIdx) = 1:numel(hullIdx);
        faces = idxMap(faces);
    end
    tHull = toc;

    % MMB shape metrics

    % Volume centroid via divergence theorem
    a = vertices(faces(:,1), :);
    b = vertices(faces(:,2), :);
    c = vertices(faces(:,3), :);
    sv = sum(a .* cross(b, c, 2), 2) / 6;
    tc = (a + b + c) / 4;
    volCentroid = sum(sv .* tc, 1) / sum(sv);
    center = volCentroid;
    if flat
        volCentroid = NaN(1, 3);
        center = mean(vertices, 1);
    end

    % Surface area from triangular faces
    e1 = vertices(faces(:,2),:) - vertices(faces(:,1),:);
    e2 = vertices(faces(:,3),:) - vertices(faces(:,1),:);
    surfaceArea = sum(0.5 * sqrt(sum(cross(e1, e2, 2).^2, 2)));

    % Sphericity (isoperimetric quotient), 1.0 for a sphere
    sphericity = (36 * pi * vol^2) / surfaceArea^3;

    % Maximum diameter (iterative O(n), not O(n^2))
    [~, idx] = max(sum((vertices - center).^2, 2));
    for iter = 1:5
        d2 = sum((vertices - vertices(idx,:)).^2, 2);
        [~, idx] = max(d2);
    end
    maxDiameter = sqrt(max(d2));

    % Principal axes (PCA of boundary vertices)
    Vc = vertices - center;
    [~, S, princDirs] = svd(Vc, 'econ');
    princLengths = diag(S);
    princLengths = [princLengths; zeros(3 - numel(princLengths), 1)] / sqrt(size(vertices,1));

    % Group coplanar triangles using aligned outward normals and matching
    % signed plane offsets. Opposite facets must remain separate. The count
    % depends on the relative normal and offset tolerances recorded below.
    normalTol = 1e-6;                                   % on dot(n_i, n_j), dimensionless
    faceNormals = cross(e1, e2, 2);
    faceNormals = faceNormals ./ sqrt(sum(faceNormals.^2, 2));
    faceOffsets = sum(faceNormals .* vertices(faces(:,1),:), 2);
    offsetTol = 1e-8 * max([1; abs(faceOffsets)]);      % relative, scale-invariant
    nF = size(faces, 1);
    visited = false(nF, 1);
    faceGroupSizes = [];
    for i = 1:nF
        if visited(i), continue; end
        dotN = faceNormals * faceNormals(i,:)';
        sameNormal = abs(dotN - 1) < normalTol;
        sameOffset = abs(faceOffsets - faceOffsets(i)) < offsetTol;
        group = find(sameNormal & sameOffset & ~visited);
        visited(group) = true;
        faceGroupSizes(end+1) = numel(group); %#ok<AGROW>
    end
    trueFaceCount = numel(faceGroupSizes);
    nTriangles = sum(faceGroupSizes == 1);
    nQuads = sum(faceGroupSizes == 2);
    nPentagons = sum(faceGroupSizes == 3);
    nHigher = sum(faceGroupSizes > 3);

    result = emptyResult;
    result.vertices = vertices;
    result.faces = faces;
    result.nVertices = size(vertices, 1);
    result.nFaces = size(faces, 1);
    result.hullVolume = vol;
    result.volumeCentroid = volCentroid;
    result.vertexCentroid = mean(vertices, 1);
    result.center = center;
    result.surfaceArea = surfaceArea;
    result.sphericity = sphericity;
    result.maxDiameter = maxDiameter;
    result.princLengths = princLengths;
    result.princDirs = princDirs;
    result.trueFaceCount = trueFaceCount;
    result.faceGroupSizes = faceGroupSizes;
    result.datasetId = datasetId;
    result.header = header;
    result.rawVertCount = nRaw;
    result.nNonFinite = nNonFinite;
    result.partial = partial;

    if options.Verbose
        fprintf("  Boundary vertices: %d\n", result.nVertices);
        fprintf("  Boundary faces:    %d (%d true faces: %d tri, %d quad, %d pent, %d higher)\n", ...
            result.nFaces, trueFaceCount, nTriangles, nQuads, nPentagons, nHigher);
        fprintf("  Hull volume:       %.15e\n", vol);
        fprintf("  Surface area:      %.6e\n", surfaceArea);
        fprintf("  Sphericity:        %.4f\n", sphericity);
        fprintf("  Max diameter:      %.2f\n", maxDiameter);
        fprintf("  Vol centroid:      [%.6f, %.6f, %.6f]\n", volCentroid);
        fprintf("  Principal extents: [%.2f, %.2f, %.2f]\n", princLengths);
        fprintf("  Hull time:         %.2fs\n", tHull);
    end

    vPath = fullfile(outDir, "mmb_" + datasetId + "_vertices.csv");
    fPath = fullfile(outDir, "mmb_" + datasetId + "_faces.csv");
    sPath = fullfile(outDir, "mmb_" + datasetId + "_summary.txt");

    writeVerticesCsv(vPath, vertices);
    writeFacesCsv(fPath, faces);

    result.verticesSha256 = fileSha256(vPath);
    result.facesSha256 = fileSha256(fPath);

    % Read the written files back to check for write or precision errors.
    % The %.17g format preserves double values on a text round trip.
    if options.SelfVerify
        Vread = readmatrix(vPath, FileType="text");
        if ~isequal(size(Vread), size(vertices)) || ~isequal(Vread, vertices)
            error("hullMMB:selfVerifyVertices", ...
                "Re-read of %s does not match written data (disk full/quota?).", vPath);
        end
        if flat
            % A flat body has an empty faces file, and its written
            % vertices must still be flat
            fInfo = dir(fPath);
            if fInfo.bytes ~= 0
                error("hullMMB:selfVerifyFaces", ...
                    "%s should be empty for a flat body but holds %d bytes.", fPath, fInfo.bytes);
            end
            if ~isFlat(Vread)
                error("hullMMB:selfVerifyVolume", ...
                    "Vertices re-read from %s are not flat, but volume 0 is reported.", vPath);
            end
        else
            Fread = readmatrix(fPath, FileType="text");
            if ~isequal(Fread, double(faces))
                error("hullMMB:selfVerifyFaces", ...
                    "Re-read of %s does not match written data (disk full/quota?).", fPath);
            end
            [~, volCheck] = convhulln(Vread);
            if abs(volCheck - vol) > 1e-12 * abs(vol)
                error("hullMMB:selfVerifyVolume", ...
                    "Volume recomputed from written bytes (%.15e) != reported (%.15e).", ...
                    volCheck, vol);
            end
        end
    end

    writeSummary(sPath, result, flat, options.Tol, normalTol, offsetTol, nFiles);

    if options.Verbose
        fprintf("  Saved + self-verified: %s_{vertices.csv,faces.csv,summary.txt}\n\n", ...
            "mmb_" + datasetId);
    end

    mmb(gi) = result;
end
end


function flat = isFlat(points)
% ISFLAT  True when the width along a principal axis is at most 1e-8 of the
%   largest coordinate.
    centered = points - mean(points, 1);
    [~, ~, principal] = svd(centered, "econ");
    along = centered * principal;
    widths = max(along, [], 1) - min(along, [], 1);
    flat = min(widths) <= 1e-8 * max(abs(points), [], "all");
end


function [groups, groupDatasetIds] = groupChunkFiles(vertexFiles)
% GROUPCHUNKFILES  Group chunk files by base dataset. Non-chunks stay solo
%   Files matching *_chunk\d+.txt are grouped by the part before _chunkN.
%   Non-chunk files each form their own group.
    chunkPattern = "^(.+)_chunk\d+$";
    datasetIds = strings(size(vertexFiles));
    isChunk = false(size(vertexFiles));
    for i = 1:numel(vertexFiles)
        [~, fname] = fileparts(vertexFiles(i));
        tokens = regexp(fname, chunkPattern, 'tokens');
        if ~isempty(tokens)
            datasetIds(i) = tokens{1}{1};
            isChunk(i) = true;
        else
            datasetIds(i) = fname;
        end
    end
    % Strip the kernel-output prefix so the dataset matches the generators file dataset
    mask = startsWith(datasetIds, "mmb_");
    datasetIds(mask) = extractAfter(datasetIds(mask), "mmb_");

    uniqueDatasetIds = unique(datasetIds, 'stable');
    groups = cell(numel(uniqueDatasetIds), 1);
    groupDatasetIds = strings(numel(uniqueDatasetIds), 1);
    for i = 1:numel(uniqueDatasetIds)
        mask = datasetIds == uniqueDatasetIds(i);
        groups{i} = vertexFiles(mask);
        groupDatasetIds(i) = uniqueDatasetIds(i);
    end
end


function h = parseKernelHeader(vfile)
% PARSEKERNELHEADER  Read leading comment lines and extract identity fields
    fid = fopen(vfile, 'r');
    assert(fid > 0, "hullMMB:cannotOpen", "Cannot open %s", vfile);
    cleanupObj = onCleanup(@() fclose(fid));
    h.headerText = "";
    h.inputBase = "";
    h.chunk = NaN;
    h.nchunks = NaN;
    h.vertices = -1;
    while true
        line = fgetl(fid);
        if ~ischar(line) || isempty(line) || line(1) ~= '%'
            break
        end
        h.headerText = h.headerText + string(line) + newline;
        tok = regexp(line, '^% Input: (\S+)', 'tokens', 'once');
        if ~isempty(tok)
            [~, base, ext] = fileparts(tok{1});
            h.inputBase = string(base) + string(ext);
        end
        tok = regexp(line, '^% chunk=(\d+), nchunks=(\d+)', 'tokens', 'once');
        if ~isempty(tok)
            h.chunk = str2double(tok{1});
            h.nchunks = str2double(tok{2});
        end
        tok = regexp(line, 'vertices=(\d+)', 'tokens', 'once');
        if ~isempty(tok) && ~startsWith(line, '% complete')
            h.vertices = str2double(tok{1});
        end
    end
end


function writeVerticesCsv(outpath, vertices)
% WRITEVERTICESCSV  Nx3 boundary vertices in %.17g, an exact double round trip
    fid = fopen(outpath, 'w');
    assert(fid > 0, "hullMMB:cannotWrite", "Cannot write %s", outpath);
    cleanupObj = onCleanup(@() fclose(fid));
    fprintf(fid, '%.17g,%.17g,%.17g\n', vertices');
end


function writeFacesCsv(outpath, faces)
% WRITEFACESCSV  Mx3 face indices as headerless CSV (1-based)
    fid = fopen(outpath, 'w');
    assert(fid > 0, "hullMMB:cannotWrite", "Cannot write %s", outpath);
    cleanupObj = onCleanup(@() fclose(fid));
    % fprintf with no faces would still write one byte. A flat body's file is empty
    if ~isempty(faces)
        fprintf(fid, '%d,%d,%d\n', faces');
    end
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


function writeSummary(outpath, result, flat, dedupTol, normalTol, offsetTol, nInputFiles)
% WRITESUMMARY  Human-readable summary with provenance and content hashes
    nTriangles = sum(result.faceGroupSizes == 1);
    nQuads = sum(result.faceGroupSizes == 2);
    nPentagons = sum(result.faceGroupSizes == 3);
    nHigher = sum(result.faceGroupSizes > 3);
    fid = fopen(outpath, 'w');
    assert(fid > 0, "hullMMB:cannotWrite", "Cannot write %s", outpath);
    cleanupObj = onCleanup(@() fclose(fid));
    fprintf(fid, "%s\n", result.header);
    if result.partial
        fprintf(fid, "%% PARTIAL: hulled from an INCOMPLETE chunk set (AllowPartial). NOT release data.\n");
    end
    fprintf(fid, "Boundary vertices: %d\n", result.nVertices);
    fprintf(fid, "Boundary faces:    %d\n", result.nFaces);
    if flat
        fprintf(fid, "Flat body:         width along a principal axis <= 1e-8 of the largest coordinate, volume 0, no faces\n");
    end
    fprintf(fid, "True faces:        %d (%d tri, %d quad, %d pent, %d higher) [tolerance-dependent, non-canonical; normalTol=%.1e, offsetTol=%.3e rel]\n", ...
        result.trueFaceCount, nTriangles, nQuads, nPentagons, nHigher, normalTol, offsetTol);
    fprintf(fid, "Hull volume:       %.15e\n", result.hullVolume);
    fprintf(fid, "Center:            [%.6f, %.6f, %.6f]\n", result.center);
    fprintf(fid, "Volume centroid:   [%.6f, %.6f, %.6f]\n", result.volumeCentroid);
    fprintf(fid, "Vertex centroid:   [%.6f, %.6f, %.6f]\n", result.vertexCentroid);
    fprintf(fid, "Surface area:      %.6e\n", result.surfaceArea);
    fprintf(fid, "Sphericity:        %.4f\n", result.sphericity);
    fprintf(fid, "Max diameter:      %.6f\n", result.maxDiameter);
    fprintf(fid, "Principal extents: [%.6f, %.6f, %.6f]\n", result.princLengths);
    fprintf(fid, "%% hull_inputs=%d raw_vertices=%d nonfinite_removed=%d dedup_tol=%.1e(relative)\n", ...
        nInputFiles, result.rawVertCount, result.nNonFinite, dedupTol);
    fprintf(fid, "%% vertices_sha256=%s\n", result.verticesSha256);
    fprintf(fid, "%% faces_sha256=%s\n", result.facesSha256);
end
