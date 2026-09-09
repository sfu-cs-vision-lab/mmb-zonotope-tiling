function files = prepareGenerators(observer, illum1s, illum2s, options)
% PREPAREGENERATORS  Build generator files for the CUDA kernel from CIE data
%
%   files = prepareGenerators(observer, illum1, illum2) generates a text file
%   containing the 6xn generator matrix for computing the exact metamer
%   mismatch body between two illuminants. Reads CIE CSV data and companion
%   JSON metadata files directly. No hardcoded DOIs or descriptions.
%
%   INPUTS:
%       observer   Observer short name (string). One of:
%                    "1931_2deg", "1964_10deg", "cfb_2deg", "cfb_10deg",
%                    "lms_2deg", "lms_10deg"
%                  If the name ends in ".csv", it is treated as a path to a
%                  user-provided four-column CSV of wavelength (nm) and three
%                  color-matching functions or channel sensitivities.
%                  Negative values are allowed. ObserverNorm is then
%                  required. See CUSTOM OBSERVER below.
%       illum1s    Illuminant 1 name(s) (string or string array).
%                  Supported: "A", "D50", "D65", "E",
%                  "FL1"-"FL12", "FL3.1"-"FL3.15",
%                  "LED-B1"-"LED-B5", "LED-BH1", "LED-RGB1", "LED-V1", "LED-V2"
%       illum2s    Illuminant 2 name(s) (string or string array, same size).
%                  If a name ends in ".csv", it is treated as a path to a
%                  user-provided two-column CSV (wavelength nm, SPD).
%
%   OPTIONAL INPUTS (Name-Value arguments):
%       Spacing    Wavelength bin width in nm (double array). Default: 10
%       Refl       Reflectance level(s) for flat-gray target color (double).
%                  Default: 0.5. Ignored if Z0 or Spectrum is provided.
%       Z0         Explicit target tristimulus values (3x1 double).
%                  Overrides Refl.
%       Spectrum   Path to CSV file with reflectance spectrum (string).
%                  Two columns: wavelength (nm), reflectance (0-1).
%                  Overrides Refl. The spectrum is interpolated onto the
%                  1 nm wavelengths the generators retain, then averaged
%                  within each complete band to one reflectance per band.
%                  The target is those band reflectances applied to the
%                  normalized first-mechanism generators, so a constant
%                  spectrum gives the same target as the equal Refl value.
%                  The spectrum must cover the retained range. Values
%                  outside it are never extrapolated.
%       DataDir    Path to CIE CSV and JSON metadata files (string).
%                  The default, also used when the given path does not
%                  exist, is the data directory shipped with this function.
%       OutputDir   Output directory (string). Default: "."
%       WlRange    Wavelength range [min max] in nm (1x2 double). Default: [380 780]
%       ObserverNorm   Normalization for a custom observer CSV (string).
%                  Required with a custom observer, and rejected with a
%                  named one. Either:
%                    "white_y100"    scale each illuminant so the second
%                                    channel of a perfect reflector
%                                    integrates to 100. Use for XYZ-like
%                                    color-matching functions.
%                    "as_supplied"   use the channel values unchanged.
%
%   OUTPUTS:
%       files   String array of generated file paths
%
%   EXAMPLE:
%       prepareGenerators("1931_2deg", "D65", "A", Spacing=10, Refl=0.5)
%       prepareGenerators("1931_2deg", "D65", "A", Spacing=[10,5,1])
%       prepareGenerators("1931_2deg", "D65", "A", Z0=[48.5; 50.1; 43.2])
%       prepareGenerators("cfb_2deg", "D65", "FL11", Spectrum="munsell_5R.csv")
%       prepareGenerators("1931_2deg", "D65", "my_led_panel.csv", Spacing=10)
%       prepareGenerators("my_camera.csv", "D65", "A", Spacing=10, ...
%                         ObserverNorm="as_supplied")
%
%   Metadata (DOIs, descriptions, interpolation methods) is read at runtime
%   from CIE JSON metadata files that accompany each CSV. These follow the
%   CIEmetaDigitalProduct schema (https://doi.org/10.25039/CIE.SC.4taqevcd).
%   All CIE data used under CC BY-SA 4.0.
%
%   NORMALIZATION CONVENTION (per observer family):
%     - XYZ-family observers (1931_2deg, 1964_10deg, cfb_2deg, cfb_10deg)
%       are normalized so that Y_white = 100 under each illuminant. By CIE
%       convention all three channels are rescaled for each illuminant by
%       k = 100 / sum of Y for a perfect white reflector.
%     - LMS observers (lms_2deg, lms_10deg) are retained at the
%       Stockman-Sharpe unit-peak cone fundamentals (the CIE 170-2:2015
%       convention, in which L, M and S each peak near 1.0 with no
%       per-illuminant rescale).
%     Because the two families use different normalizations, absolute
%     MMB volumes are not comparable across observer families. Shape and
%     relative metamerism are still well-defined within each family.
%
%   CUSTOM OBSERVER:
%     The CSV has no header. Its four columns are the wavelength in nm, then
%     three channels. Wavelengths must increase strictly, with no repeats, and
%     every value must be finite. The three channels may be signed.
%
%         380,0.0014,0.0000,0.0065
%         381,0.0022,0.0001,0.0105
%         ...
%
%     The dataset identifier uses the file base name made into a valid
%     identifier, so the path never appears in a dataset_id. The generators
%     header records the source path, its SHA-256 and the normalization.
%     No DOI, CIE metadata or license is claimed for a user-supplied file.
%
%     A custom observer is used in the same role as a named one. It does not
%     allow a different observer per illuminant.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    observer (1,1) string
    illum1s (1,:) string
    illum2s (1,:) string
    options.Spacing (1,:) double = 10
    options.Refl (1,:) double = 0.5
    options.Z0 double = []
    options.Spectrum (1,1) string = ""
    options.DataDir (1,1) string = ""
    options.OutputDir (1,1) string = "."
    options.WlRange (1,2) double = [380 780]
    options.ObserverNorm (1,1) string = ""
end

dataDir = resolveDataDir(options.DataDir);
if ~isfolder(options.OutputDir)
    mkdir(options.OutputDir);
end

% Expand scalar arguments to match array sizes
nPairs = max(numel(illum1s), numel(illum2s));
if isscalar(illum1s)
    illum1s = repmat(illum1s, 1, nPairs);
end
if isscalar(illum2s)
    illum2s = repmat(illum2s, 1, nPairs);
end
reflLevels = options.Refl;
if isscalar(reflLevels)
    reflLevels = repmat(reflLevels, 1, nPairs);
end
assert(numel(illum1s) == numel(illum2s) && numel(illum1s) == numel(reflLevels), ...
    'prepareGenerators:SizeMismatch', ...
    'illum1s, illum2s and Refl must have matching lengths');

[obsWl, obsCmf, obsInfo] = loadObserver(observer, dataDir, options.ObserverNorm);
obsLabel = obsInfo.label;
if obsInfo.custom
    fprintf("Observer: %s (user-supplied, %s, sha256 %s)\n", ...
        obsLabel, obsInfo.normPolicy, extractBefore(obsInfo.sha256, 17));
else
    fprintf("Observer: %s (%s)\n", obsLabel, obsInfo.doi);
end

nSpacings = numel(options.Spacing);
totalFiles = nSpacings * nPairs;
files = strings(totalFiles, 1);
fileIdx = 0;

for si = 1:nSpacings
    sp = options.Spacing(si);
    for pi = 1:nPairs
        i1 = illum1s(pi);
        i2 = illum2s(pi);
        rl = reflLevels(pi);
        fileIdx = fileIdx + 1;

        [s1Wl, s1Spd, s1Info] = loadIlluminant(i1, dataDir);
        [s2Wl, s2Spd, s2Info] = loadIlluminant(i2, dataDir);

        [g1, g2, wlBins, k1, k2, normChannel, wlKept] = buildGenerators( ...
            obsWl, obsCmf, s1Wl, s1Spd, s2Wl, s2Spd, sp, options.WlRange, ...
            obsInfo.normPolicy);

        nBins = size(g1, 2);

        % Determine z0 and filename tag
        if ~isempty(options.Z0)
            z0 = options.Z0(:);
            z0Tag = sprintf("z0_%.0f_%.0f_%.0f", z0(1), z0(2), z0(3));
            z0Desc = sprintf("explicit z0 = [%.6f, %.6f, %.6f]", z0);
        elseif options.Spectrum ~= ""
            [z0, z0Desc] = computeZ0FromSpectrum( ...
                options.Spectrum, g1, wlKept, sp);
            specBase = matlab.lang.makeValidName(extractBefore( ...
                extractAfter(options.Spectrum, max(strfind(options.Spectrum, filesep))), "."));
            z0Tag = "spec_" + specBase;
        else
            z0 = rl * sum(g1, 2);
            z0Tag = sprintf("refl%d", round(rl * 100));
            z0Desc = sprintf("%.0f%% flat reflectance under illuminant 1", rl * 100);
        end

        i1Label = illumLabel(i1);
        i2Label = illumLabel(i2);
        fname = sprintf("generators_%s_%s_%s_%dnm_%s.txt", ...
            obsLabel, i1Label, i2Label, sp, z0Tag);
        outpath = fullfile(options.OutputDir, fname);

        writeOutput(outpath, nBins, z0, g1, g2, wlBins, sp, z0Desc, ...
            obsLabel, obsInfo, i1, s1Info, i2, s2Info, options.WlRange, ...
            k1, k2, normChannel, obsInfo.normPolicy);

        files(fileIdx) = outpath;
        fprintf("  [%s->%s, %dnm, %s] n=%d, C(%d,6)=%.3e -> %s\n", ...
            i1, i2, sp, z0Tag, nBins, nBins, nchoosek(nBins, 6), fname);
    end
end
files = files(1:fileIdx);
fprintf("\n%d file(s) written to %s/\n", fileIdx, options.OutputDir);
end


% Reading CIE JSON metadata

function meta = readCieMetadata(csvFile, dataDir)
% READCIEMETADATA  Read companion JSON metadata for a CIE CSV file
%   By CIE convention, "<name>.csv" has its metadata in "<name>_csv_metadata.json".
    [~, datasetId] = fileparts(csvFile);
    jsonFile = fullfile(dataDir, datasetId + "_csv_metadata.json");
    assert(isfile(jsonFile), 'prepareGenerators:MetadataNotFound', ...
        'CIE metadata file not found: %s', jsonFile);
    raw = jsondecode(fileread(jsonFile));
    meta.doi = raw.identifier.identifier;
    meta.title = raw.titles(1).title;
    meta.desc = raw.descriptions(1).description;
    meta.interp = raw.datatableInfo.interpolationMethod;
    meta.license = raw.rightsList(1).rights;
    meta.file = csvFile;

    % Parse column headers (jsondecode returns a struct array when all
    % objects share the same fields, or a cell array of structs when
    % fields differ. E.g. FL/LED files where the lambda column lacks
    % "description" but the illuminant columns have it)
    headers = raw.datatableInfo.columnHeaders;
    if isstruct(headers)
        nCols = numel(headers);
        meta.colTitles = strings(nCols, 1);
        meta.colQuantities = strings(nCols, 1);
        for c = 1:nCols
            meta.colTitles(c) = string(headers(c).title);
            meta.colQuantities(c) = string(headers(c).quantity);
        end
    elseif iscell(headers)
        nCols = numel(headers);
        meta.colTitles = strings(nCols, 1);
        meta.colQuantities = strings(nCols, 1);
        for c = 1:nCols
            meta.colTitles(c) = string(headers{c}.title);
            meta.colQuantities(c) = string(headers{c}.quantity);
        end
    end
end

function col = findColumnByTitle(meta, colTitle)
% FINDCOLUMNBYTITLE  Find 1-based column index matching a title in metadata
    idx = find(meta.colTitles == colTitle, 1);
    assert(~isempty(idx), 'prepareGenerators:ColumnNotFound', ...
        'Column "%s" not found in %s. Available: %s', ...
        colTitle, meta.file, join(meta.colTitles, ", "));
    col = idx;
end


% Data directory resolution

function dataDir = resolveDataDir(requestedDir)
% Resolve the CIE data directory.
%
% A requested directory is used when it exists. Run definitions pass a
% relative path such as "data", and mmb_run.sh runs them from a private
% preparation directory, so a relative request that does not resolve from
% the current folder falls back to the data directory shipped beside this
% function. The search order for an empty request is that same shipped
% directory, then ./data, then the current folder.
    shipped = fullfile(fileparts(mfilename('fullpath')), '..', 'data');
    if requestedDir ~= "" && isfolder(requestedDir)
        dataDir = requestedDir;
    elseif isfolder(shipped)
        dataDir = shipped;
    elseif isfolder(fullfile(pwd, 'data'))
        dataDir = fullfile(pwd, 'data');
    else
        assert(requestedDir == "", 'prepareGenerators:DataDirNotFound', ...
            'DataDir "%s" does not exist and no data directory was found', ...
            requestedDir);
        dataDir = pwd;
    end
end


% Observer loading

function [wl, cmf, info] = loadObserver(name, dataDir, normOpt)
% LOADOBSERVER  Load observer CMFs from a named CIE table or a user CSV
    if endsWith(name, ".csv", IgnoreCase=true)
        [wl, cmf, info] = loadCustomObserver(name, normOpt);
        return
    end
    assert(normOpt == "", 'prepareGenerators:ObserverNormNotApplicable', ...
        ['ObserverNorm applies only to a custom observer CSV. The named ' ...
         'observer "%s" has a fixed normalization.'], name);
    reg = getObserverRegistry();
    assert(isKey(reg, name), 'prepareGenerators:UnknownObserver', ...
        'Unknown observer: %s. Options: %s', name, join(keys(reg), ", "));
    entry = reg(name);

    meta = readCieMetadata(entry.file, dataDir);
    fpath = fullfile(dataDir, entry.file);
    assert(isfile(fpath), 'prepareGenerators:FileNotFound', ...
        'Observer file not found: %s', fpath);

    raw = readmatrix(fpath);
    wl = raw(:, 1);
    cmf = raw(:, 2:4);
    cmf(isnan(cmf)) = 0;

    % Apply inverse transform for derived observers (LMS from cfb)
    if any(entry.invMatrix(:) ~= 0)
        cmf = (entry.invMatrix * cmf')';
    end

    info.doi = meta.doi;
    info.desc = meta.desc;
    info.interp = meta.interp;
    info.file = entry.file;
    info.derivedNote = entry.derivedNote;
    info.normPolicy = entry.normPolicy;
    info.custom = false;
    info.sha256 = "";
    info.label = name;
end


function [wl, cmf, info] = loadCustomObserver(path, normOpt)
% LOADCUSTOMOBSERVER  Read and check a user-supplied four-column observer CSV
%
%   Columns: wavelength in nm, then three color-matching functions or
%   channel sensitivities. Negative values are allowed, because
%   color-matching functions are signed.

    assert(ismember(normOpt, ["white_y100", "as_supplied"]), ...
        'prepareGenerators:ObserverNormRequired', ...
        ['A custom observer CSV needs an explicit normalization. Pass ' ...
         'ObserverNorm="white_y100" to scale each illuminant so the second ' ...
         'channel of a perfect reflector integrates to 100, or ' ...
         'ObserverNorm="as_supplied" to use the supplied values unchanged.']);

    fpath = resolveUserFile(path, "observer");
    raw = readmatrix(fpath);

    assert(~isempty(raw) && size(raw, 1) >= 2, ...
        'prepareGenerators:BadObserverFile', ...
        'Custom observer file has fewer than two data rows: %s', fpath);
    assert(size(raw, 2) == 4, 'prepareGenerators:BadObserverFile', ...
        ['Custom observer file must have exactly four columns ' ...
         '(wavelength nm, then three channels). Found %d in %s.'], ...
        size(raw, 2), fpath);
    assert(all(isfinite(raw), 'all'), 'prepareGenerators:BadObserverFile', ...
        ['Custom observer file contains a non-finite or missing value. ' ...
         'Rows with NaN or Inf are not accepted: %s'], fpath);

    wl = raw(:, 1);
    assert(all(diff(wl) > 0), 'prepareGenerators:BadObserverFile', ...
        ['Custom observer wavelengths must increase strictly, with no ' ...
         'repeats and no out-of-order rows: %s'], fpath);

    cmf = raw(:, 2:4);
    assert(any(cmf(:) ~= 0), 'prepareGenerators:BadObserverFile', ...
        'Custom observer channels are all zero: %s', fpath);

    info = struct( ...
        'doi', "", ...
        'desc', "User-supplied observer", ...
        'interp', "linear", ...
        'file', string(fpath), ...
        'derivedNote', "", ...
        'normPolicy', normOpt, ...
        'custom', true, ...
        'sha256', fileSha256(fpath), ...
        'label', observerLabel(path));
end


function reg = getObserverRegistry()
% Observer registry: short name -> CSV filename + optional inverse transform.
% All metadata (DOI, description, interpolation) is read from JSON at runtime.
    noTransform = zeros(3);

    % CIE 170-2:2015 transformation matrices: XYZ_F = T * LMS
    t2 = [1.94735469  -1.41445123   0.36476327; ...
          0.68990272   0.34832189   0;           ...
          0            0            1.93485343];
    t10 = [1.93986443  -1.34664359   0.43044935; ...
           0.69283932   0.34967567   0;           ...
           0            0            2.14687945];

    % Normalization policy per observer:
    %   "white_y100"     Scale each illuminant so the middle (Y-like)
    %                    channel of a perfect-white reflector integrates
    %                    to 100. CIE standard for XYZ-family observers.
    %   "unit_peak"      No rescale. Preserves the Stockman-Sharpe
    %                    unit-peak normalization of the LMS cone
    %                    fundamentals derived as inv(T) * cfb.
    reg = dictionary( ...
        "1931_2deg",  struct('file', "CIE_xyz_1931_2deg.csv",  'invMatrix', noTransform, 'derivedNote', "",                                                              'normPolicy', "white_y100"), ...
        "1964_10deg", struct('file', "CIE_xyz_1964_10deg.csv", 'invMatrix', noTransform, 'derivedNote', "",                                                              'normPolicy', "white_y100"), ...
        "cfb_2deg",   struct('file', "CIE_cfb_stv_2deg.csv",  'invMatrix', noTransform, 'derivedNote', "",                                                              'normPolicy', "white_y100"), ...
        "cfb_10deg",  struct('file', "CIE_cfb_stv_10deg.csv", 'invMatrix', noTransform, 'derivedNote', "",                                                              'normPolicy', "white_y100"), ...
        "lms_2deg",   struct('file', "CIE_cfb_stv_2deg.csv",  'invMatrix', inv(t2),     'derivedNote', "Derived via inv(T), CIE 170-2:2015 Table 10.2",  'normPolicy', "unit_peak"), ...
        "lms_10deg",  struct('file', "CIE_cfb_stv_10deg.csv", 'invMatrix', inv(t10),    'derivedNote', "Derived via inv(T), CIE 170-2:2015 Table 10.5", 'normPolicy', "unit_peak") ...
    );
end


% Illuminant loading

function [wl, spd, info] = loadIlluminant(name, dataDir)
% LOADILLUMINANT  Load CIE illuminant SPD from CSV with metadata from JSON
%   If name ends in ".csv", loads a user-provided two-column CSV file.

    if strcmpi(name, "E")
        wl = (300:830)';
        spd = ones(size(wl));
        info = struct('file', "none", 'doi', "N/A", ...
            'desc', "Equal energy illuminant E (constant SPD)", ...
            'interp', "N/A", 'col', 0);
        return
    end

    if endsWith(name, ".csv", IgnoreCase=true)
        name = resolveUserFile(name, "illuminant");
        raw = readmatrix(name);
        wl = raw(:, 1);
        spd = raw(:, 2);
        spd(isnan(spd)) = 0;
        info = struct('file', name, 'doi', "N/A", ...
            'desc', sprintf("User-provided illuminant from %s", name), ...
            'interp', "N/A", 'col', 2);
        return
    end

    reg = getIlluminantRegistry();
    assert(isKey(reg, name), 'prepareGenerators:UnknownIlluminant', ...
        'Unknown illuminant: %s. Options: %s', name, join(keys(reg), ", "));
    entry = reg(name);

    meta = readCieMetadata(entry.file, dataDir);
    fpath = fullfile(dataDir, entry.file);
    assert(isfile(fpath), 'prepareGenerators:FileNotFound', ...
        'Illuminant file not found: %s', fpath);

    raw = readmatrix(fpath);
    wl = raw(:, 1);

    % For multi-column files, find the right column from JSON metadata
    if entry.colTitle ~= ""
        colIdx = findColumnByTitle(meta, entry.colTitle);
    else
        colIdx = 2;
    end
    spd = raw(:, colIdx);
    spd(isnan(spd)) = 0;

    info.doi = meta.doi;
    info.desc = meta.desc;
    info.interp = meta.interp;
    info.file = entry.file;
    info.col = colIdx;
end


function reg = getIlluminantRegistry()
% Illuminant registry: short name -> CSV filename + column title for lookup.
% For single-column files, colTitle is "" (uses column 2).
% For multi-column files, colTitle matches the JSON columnHeaders title.
    reg = dictionary();

    % Single-column standard illuminants
    reg("A")   = struct('file', "CIE_std_illum_A_1nm.csv", 'colTitle', "");
    reg("D50") = struct('file', "CIE_std_illum_D50.csv",   'colTitle', "");
    reg("D65") = struct('file', "CIE_std_illum_D65.csv",   'colTitle', "");

    % Fluorescent (multi-column, matched by JSON column title)
    flNames = ["FL1","FL2","FL3","FL4","FL5","FL6", ...
               "FL7","FL8","FL9","FL10","FL11","FL12", ...
               "FL3.1","FL3.2","FL3.3","FL3.4","FL3.5","FL3.6", ...
               "FL3.7","FL3.8","FL3.9","FL3.10","FL3.11","FL3.12", ...
               "FL3.13","FL3.14","FL3.15"];
    for i = 1:numel(flNames)
        reg(flNames(i)) = struct( ...
            'file', "CIE_illum_FLs_1nm.csv", ...
            'colTitle', flNames(i));
    end

    % LED (multi-column, matched by JSON column title)
    ledNames = ["LED-B1","LED-B2","LED-B3","LED-B4","LED-B5", ...
                "LED-BH1","LED-RGB1","LED-V1","LED-V2"];
    for i = 1:numel(ledNames)
        reg(ledNames(i)) = struct( ...
            'file', "CIE_illum_LEDs_1nm.csv", ...
            'colTitle', ledNames(i));
    end
end


% Generator construction

function [g1, g2, wlBins, k1, k2, normChannel, wlKept] = buildGenerators( ...
        obsWl, obsCmf, s1Wl, s1Spd, s2Wl, s2Spd, spacing, wlRange, normPolicy)
% BUILDGENERATORS  Construct 3xn generator matrices for both illuminants
%
%   Interpolates observer and illuminants to a common 1nm grid, computes
%   per-wavelength generators, then bins to the requested spacing by
%   summing (CIE-recommended rectangular integration).
%
%   normPolicy controls the per-illuminant rescale:
%     "white_y100"    K = 100 / sum of middle channel for a perfect
%                     white reflector (CIE convention for XYZ-family).
%     "unit_peak"     K = 1. Preserves the unit-peak normalization of
%                     LMS cone fundamentals derived as inv(T) * cfb.
%     "as_supplied"   K = 1. A user-supplied observer is used as given.

    wlMin = max([wlRange(1), min(obsWl), min(s1Wl), min(s2Wl)]);
    wlMax = min([wlRange(2), max(obsWl), max(s1Wl), max(s2Wl)]);
    wl1nm = (wlMin:wlMax)';
    n1nm = numel(wl1nm);

    cmf1nm = interp1(obsWl, obsCmf, wl1nm, 'linear', 0);
    spd1 = interp1(s1Wl, s1Spd, wl1nm, 'linear', 0);
    spd2 = interp1(s2Wl, s2Spd, wl1nm, 'linear', 0);

    g1Full = cmf1nm' .* spd1';
    g2Full = cmf1nm' .* spd2';

    assert(wlMax > wlMin, 'prepareGenerators:NoSpectralOverlap', ...
        ['The observer, the two illuminants and WlRange do not overlap. ' ...
         'Overlap resolved to [%g %g] nm.'], wlMin, wlMax);
    nBins = floor(n1nm / spacing);
    assert(nBins >= 1, 'prepareGenerators:NoSpectralOverlap', ...
        ['The overlap of the observer, the illuminants and WlRange is ' ...
         '%d nm, which is narrower than one %d nm bin.'], n1nm, spacing);
    usable = nBins * spacing;

    g1 = squeeze(sum(reshape(g1Full(:, 1:usable), 3, spacing, nBins), 2));
    g2 = squeeze(sum(reshape(g2Full(:, 1:usable), 3, spacing, nBins), 2));
    wlKept = wl1nm(1:usable);
    wlBins = mean(reshape(wlKept, spacing, nBins), 1)';

    switch normPolicy
        case "white_y100"
            % CIE-standard: scale so middle (Y) channel integrates to 100
            % for a perfect white reflector. Same factor on all three
            % channels preserves geometry.
            %
            % The white response is the denominator of that scale. If it is
            % zero or not finite the normalization has no meaning, so say so
            % rather than dividing. Signed channels are fine. What matters
            % is that their sum is a usable number.
            normChannel = ceil(size(g1, 1) / 2);
            white1 = sum(g1(normChannel, :));
            white2 = sum(g2(normChannel, :));
            checkWhiteResponse(white1, 1, normChannel);
            checkWhiteResponse(white2, 2, normChannel);
            k1 = 100 / white1;
            k2 = 100 / white2;
            g1 = k1 * g1;
            g2 = k2 * g2;
            assert(isfinite(k1) && isfinite(k2) && ...
                all(isfinite(g1), 'all') && all(isfinite(g2), 'all'), ...
                'prepareGenerators:NonFiniteGenerators', ...
                ['Normalization produced a non-finite generator. Check the ' ...
                 'observer and illuminant data for extreme values.']);
        case "unit_peak"
            % LMS cone fundamentals arrive unit-peak normalized via
            % inv(T)*cfb. Do not rescale.
            k1 = 1;
            k2 = 1;
            normChannel = 0;
        case "as_supplied"
            % A user-supplied observer is used as given. Nothing is known
            % about its units, so no white anchor is applied and no claim
            % is made about its normalization.
            k1 = 1;
            k2 = 1;
            normChannel = 0;
        otherwise
            error('prepareGenerators:UnknownNormPolicy', ...
                'Unknown normPolicy: "%s"', normPolicy);
    end
end


% Target color from spectrum

function checkWhiteResponse(white, which, normChannel)
% CHECKWHITERESPONSE  Reject a white-anchor denominator that has no meaning
    assert(isfinite(white), 'prepareGenerators:UndefinedWhiteNormalization', ...
        ['The perfect-reflector response of channel %d under illuminant %d ' ...
         'is not finite, so white_y100 normalization is undefined. Check ' ...
         'the observer and illuminant data.'], normChannel, which);
    assert(white ~= 0, 'prepareGenerators:UndefinedWhiteNormalization', ...
        ['The perfect-reflector response of channel %d under illuminant %d ' ...
         'is exactly zero, so white_y100 normalization is undefined. That ' ...
         'channel contributes nothing, or its signed values cancel. Use ' ...
         'ObserverNorm="as_supplied" if the values are intended, or put the ' ...
         'luminance-like channel second.'], normChannel, which);
end


function [z0, desc] = computeZ0FromSpectrum(specFile, g1, wlKept, spacing)
% COMPUTEZ0FROMSPECTRUM  Target color of a reflectance spectrum
%
%   The target is computed from the same discretized problem as the
%   generators, so that a constant spectrum gives the same target as the
%   equivalent Refl value.
%
%   The spectrum is interpolated onto the 1 nm wavelengths the generators
%   retain, then reduced to one reflectance per band by averaging the
%   samples inside that band. The target is g1 * rho, using the normalized
%   first-mechanism generators. Wavelengths the binning drops and any part
%   of the spectrum outside the retained range take no part in it.

    fpath = resolveUserFile(specFile, "spectrum");
    raw = readmatrix(fpath);

    assert(~isempty(raw) && size(raw, 1) >= 2, ...
        'prepareGenerators:BadSpectrumFile', ...
        'Spectrum file has fewer than two data rows: %s', fpath);
    assert(size(raw, 2) == 2, 'prepareGenerators:BadSpectrumFile', ...
        ['Spectrum file must have exactly two columns (wavelength nm, ' ...
         'reflectance). Found %d in %s.'], size(raw, 2), fpath);
    assert(all(isfinite(raw), 'all'), 'prepareGenerators:BadSpectrumFile', ...
        'Spectrum file contains a non-finite or missing value: %s', fpath);

    specWl = raw(:, 1);
    specRefl = raw(:, 2);
    assert(all(diff(specWl) > 0), 'prepareGenerators:BadSpectrumFile', ...
        ['Spectrum wavelengths must increase strictly, with no repeats and ' ...
         'no out-of-order rows: %s'], fpath);

    % Never extrapolate. A reflectance outside the supplied range is not
    % known, so the run stops rather than inventing one.
    assert(specWl(1) <= wlKept(1) && specWl(end) >= wlKept(end), ...
        'prepareGenerators:SpectrumRange', ...
        ['Spectrum covers %g to %g nm but the generators retain %g to %g ' ...
         'nm. Supply a spectrum that covers the retained range, or narrow ' ...
         'WlRange.'], specWl(1), specWl(end), wlKept(1), wlKept(end));

    refl1nm = interp1(specWl, specRefl, wlKept, 'linear');
    nBins = numel(wlKept) / spacing;
    rhoBands = mean(reshape(refl1nm, spacing, nBins), 1)';

    z0 = g1 * rhoBands;
    desc = sprintf(['reflectance spectrum from %s, averaged to one ' ...
        'reflectance per %d nm band'], specFile, spacing);
end


% Output writing

function writeOutput(outpath, nBins, z0, g1, g2, wlBins, spacing, z0Desc, ...
        obsName, obsInfo, illum1Name, illum1Info, illum2Name, illum2Info, wlRange, ...
        k1, k2, normChannel, normPolicy)
% WRITEOUTPUT  Write color data file with full provenance header

    fid = fopen(outpath, 'w');
    cleanupObj = onCleanup(@() fclose(fid));

    fprintf(fid, "%% Exact MMB color data -- generated by prepareGenerators.m\n");
    fprintf(fid, "%% Generated: %s\n", datetime("now"));
    fprintf(fid, "%% Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.\n");
    fprintf(fid, "%%\n");
    fprintf(fid, "%% Observer: %s\n", obsName);
    if obsInfo.custom
        fprintf(fid, "%%   User-supplied observer, four-column CSV\n");
        fprintf(fid, "%%   Source file: %s\n", obsInfo.file);
        fprintf(fid, "%%   Source SHA-256: %s\n", obsInfo.sha256);
        fprintf(fid, "%%   Columns: wavelength nm, channel 1, channel 2, channel 3\n");
        fprintf(fid, "%%   Interpolation: %s\n", obsInfo.interp);
        fprintf(fid, "%%   No CIE identifier, metadata or license applies to this file\n");
    else
        fprintf(fid, "%%   %s\n", obsInfo.desc);
        fprintf(fid, "%%   DOI: https://doi.org/%s\n", obsInfo.doi);
        fprintf(fid, "%%   File: %s\n", obsInfo.file);
        fprintf(fid, "%%   Interpolation: %s\n", obsInfo.interp);
        if obsInfo.derivedNote ~= ""
            fprintf(fid, "%%   Note: %s\n", obsInfo.derivedNote);
        end
    end
    fprintf(fid, "%%\n");
    fprintf(fid, "%% Illuminant 1: %s\n", illum1Name);
    fprintf(fid, "%%   %s\n", illum1Info.desc);
    fprintf(fid, "%%   DOI: https://doi.org/%s\n", illum1Info.doi);
    fprintf(fid, "%%   File: %s, column %d\n", illum1Info.file, illum1Info.col);
    fprintf(fid, "%%   Interpolation: %s\n", illum1Info.interp);
    fprintf(fid, "%%\n");
    fprintf(fid, "%% Illuminant 2: %s\n", illum2Name);
    fprintf(fid, "%%   %s\n", illum2Info.desc);
    fprintf(fid, "%%   DOI: https://doi.org/%s\n", illum2Info.doi);
    fprintf(fid, "%%   File: %s, column %d\n", illum2Info.file, illum2Info.col);
    fprintf(fid, "%%   Interpolation: %s\n", illum2Info.interp);
    fprintf(fid, "%%\n");
    fprintf(fid, "%% Wavelength range: %d-%d nm\n", wlRange(1), wlRange(2));
    fprintf(fid, "%% Spacing: %d nm (%d bins)\n", spacing, nBins);
    fprintf(fid, "%% Target color: %s\n", z0Desc);
    fprintf(fid, "%% z0 = [%.6f, %.6f, %.6f]\n", z0(1), z0(2), z0(3));
    switch normPolicy
        case "white_y100"
            fprintf(fid, "%% Normalization: k1=%.15e, k2=%.15e (white_y100: channel %d = 100)\n", ...
                k1, k2, normChannel);
        case "unit_peak"
            fprintf(fid, "%% Normalization: k1=%.15e, k2=%.15e (unit_peak: unit-peak cone fundamentals, no white anchor)\n", ...
                k1, k2);
        case "as_supplied"
            fprintf(fid, "%% Normalization: k1=%.15e, k2=%.15e (as_supplied: user channel values kept unchanged, no white anchor)\n", ...
                k1, k2);
        otherwise
            fprintf(fid, "%% Normalization: k1=%.15e, k2=%.15e (policy=%s, channel=%d)\n", ...
                k1, k2, normPolicy, normChannel);
    end
    fprintf(fid, "%%\n");
    fprintf(fid, "%% Integration: rectangular (sum of 1nm generators per bin)\n");
    fprintf(fid, "%% Interpolation to common 1nm grid: linear, zero outside range\n");
    fprintf(fid, "%% All CIE data under CC BY-SA 4.0 (https://cie.co.at/data-tables)\n");
    fprintf(fid, "%% Metadata schema: CIEmetaDigitalProduct v4\n");
    if obsInfo.custom
        fprintf(fid, "%% The observer file is user-supplied. It is not CIE data and this\n");
        fprintf(fid, "%% software makes no license statement about it.\n");
    end
    fprintf(fid, "%%\n");
    fprintf(fid, "%% illum1=%s illum2=%s observer=%s spacing=%dnm\n", ...
        illum1Name, illum2Name, obsName, spacing);

    % Build the numeric payload as the exact byte string that follows and
    % stamp its SHA-256 into the header. The CUDA kernel copies every header
    % comment into its output, so each chunk carries the identity of the
    % problem it solved. Promotion (tools/verify_chunk.sh --generators) and
    % validation both compare it against this dataset's current generators
    % file, so a chunk computed from a different generation of the input
    % cannot be promoted under this dataset_id.
    outData = [wlBins, g1', g2'];
    payload = join([ ...
        string(sprintf("%d", nBins)); ...
        string(sprintf("%.15e %.15e %.15e", z0(1), z0(2), z0(3))); ...
        compose("%.1f %.15e %.15e %.15e %.15e %.15e %.15e", outData)], newline);
    fprintf(fid, "%% payload_sha256=%s\n", sha256OfString(payload));

    fprintf(fid, "%s\n", payload);
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


function hex = sha256OfString(s)
% SHA256OFSTRING  SHA-256 of a string's UTF-8 bytes (java, no toolbox)
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(unicode2native(char(s), 'UTF-8'));
    hex = lower(string(reshape(dec2hex(typecast(md.digest(), 'uint8'))', 1, [])));
end


function label = observerLabel(name)
% OBSERVERLABEL  Filename-safe dataset label for an observer
% A named observer keeps its name. A custom CSV contributes its file base
% name, made into a valid identifier. A path never reaches a dataset_id.
    if endsWith(name, ".csv", IgnoreCase=true)
        [~, base] = fileparts(name);
        label = matlab.lang.makeValidName(string(base));
    else
        label = name;
    end
end


function fpath = resolveUserFile(path, kind)
% RESOLVEUSERFILE  Locate a user-supplied CSV and return an absolute path
% The launcher runs the run definition from a private preparation
% directory, so a path relative to the repository or sitting beside the run
% definition on the MATLAB path must still resolve.
    candidates = string(path);
    if ~startsWith(path, filesep)
        repoRoot = fileparts(fileparts(mfilename("fullpath")));
        candidates(end+1) = fullfile(repoRoot, path);
    end
    for c = candidates
        if isfile(c)
            fpath = string(java.io.File(char(c)).getCanonicalPath());
            return
        end
    end
    onPath = string(which(char(path)));
    if onPath ~= "" && isfile(onPath)
        fpath = string(java.io.File(char(onPath)).getCanonicalPath());
        return
    end
    error('prepareGenerators:FileNotFound', ...
        ['Custom %s file not found: %s\nLooked for it as given, relative ' ...
         'to the software root and on the MATLAB path.'], kind, path);
end


function label = illumLabel(name)
% ILLUMLABEL  Convert illuminant name to a clean filename-safe label
% Standard illuminants keep their names. For a custom CSV, convert the
% filename without its extension to a valid MATLAB identifier.
    if endsWith(name, ".csv", IgnoreCase=true)
        [~, datasetId] = fileparts(name);
        label = matlab.lang.makeValidName(string(datasetId));
    else
        label = name;
    end
end
