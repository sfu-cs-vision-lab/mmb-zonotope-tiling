classdef prepareGeneratorsTest < matlab.unittest.TestCase
% PREPAREGENERATORSTEST  Tests for prepareGenerators
%
%   Run:
%       results = runtests("prepareGeneratorsTest");
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (TestParameter)
        Observer = {"1931_2deg", "1964_10deg", "cfb_2deg", "cfb_10deg", ...
                    "lms_2deg", "lms_10deg"}
        Illuminant = {"A", "D50", "D65", "FL11", "LED-B1", "E"}
        MultiColumnIlluminant = {"FL3", "FL3.7", "LED-B3"}
    end

    properties (Access = private)
        DataDir string
        OutputDir string
    end

    methods (TestMethodSetup)
        function createOutputDir(testCase)
            testCase.DataDir = fullfile(fileparts(mfilename('fullpath')), ...
                '..', 'data');
            testCase.OutputDir = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
        end
    end

    methods (Test)
        function basicGeneratesFile(testCase)
            files = prepareGenerators("1931_2deg", "D65", "A", ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyNumElements(files, 1);
            testCase.verifyTrue(isfile(files(1)));

            raw = readmatrix(files(1), CommentStyle="%");
            nBins = floor((780 - 380) / 10);
            testCase.verifyEqual(size(raw, 1), nBins);
            testCase.verifyEqual(size(raw, 2), 7);

            content = fileread(files(1));
            testCase.verifySubstring(content, "DOI:");
            testCase.verifySubstring(content, "1931_2deg");
            testCase.verifySubstring(content, "Observer:");
        end

        function observerLoads(testCase, Observer)
            files = prepareGenerators(Observer, "D65", "A", ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            % The CFB and LMS tables start at 390 nm, which leaves 39 bins.
            nBins = 40 - startsWith(Observer, ["cfb", "lms"]);
            testCase.verifyGeneratorPayload(files(1), nBins);
        end

        function illuminantLoads(testCase, Illuminant)
            files = prepareGenerators("1931_2deg", "D65", Illuminant, ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyGeneratorPayload(files(1), 40);
        end

        function lmsDerivation(testCase)
            % Check the written normalization. The LMS file is written with
            % k1=k2=1 (no rescale) and labeled with the unit_peak
            % policy. Cfb is written with the white_y100 policy.
            filesLms = prepareGenerators("lms_2deg", "D65", "A", ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            filesCfb = prepareGenerators("cfb_2deg", "D65", "A", ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            lmsHdr = fileread(filesLms(1));
            cfbHdr = fileread(filesCfb(1));
            testCase.verifySubstring(lmsHdr, "unit_peak");
            testCase.verifySubstring(lmsHdr, ...
                "k1=1.000000000000000e+00, k2=1.000000000000000e+00");
            testCase.verifySubstring(cfbHdr, "white_y100");
        end

        function z0FromRefl(testCase)
            files = prepareGenerators("1931_2deg", "D65", "A", ...
                Spacing=10, Refl=0.3, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            data = readmatrix(files(1), CommentStyle="%");
            testCase.verifyEqual(testCase.targetOf(files(1)), ...
                0.3 * sum(data(:, 2:4)', 2), "RelTol", 1e-12);
            testCase.verifySubstring(files(1), "refl30");
        end

        function multiColumnIlluminantMatchesItsTableColumn(testCase, MultiColumnIlluminant)
            % Recompute the second generators from this illuminant's own
            % column of the CIE table, found by its title in the metadata.
            if startsWith(MultiColumnIlluminant, "FL")
                tableName = "CIE_illum_FLs_1nm";
            else
                tableName = "CIE_illum_LEDs_1nm";
            end
            meta = jsondecode(fileread(fullfile(testCase.DataDir, ...
                tableName + "_csv_metadata.json")));
            titles = cellfun(@(h) string(h.title), meta.datatableInfo.columnHeaders);
            spd = readmatrix(fullfile(testCase.DataDir, tableName + ".csv"));
            spd = spd(spd(:, 1) >= 380 & spd(:, 1) <= 779, titles == MultiColumnIlluminant);
            cmf = readmatrix(fullfile(testCase.DataDir, "CIE_xyz_1931_2deg.csv"));
            cmf = cmf(cmf(:, 1) >= 380 & cmf(:, 1) <= 779, 2:4);

            files = prepareGenerators("1931_2deg", "D65", MultiColumnIlluminant, ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            data = readmatrix(files(1), CommentStyle="%");
            k = testCase.headerScale(string(fileread(files(1))));
            testCase.verifyEqual(data(:, 5:7), k(2) * testCase.binSums(cmf .* spd, 10), ...
                "RelTol", 1e-12);
        end

        function batchProducesCorrectFileCount(testCase)
            files = prepareGenerators("1931_2deg", "D65", ["A", "D50"], ...
                Spacing=[10, 5], Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyNumElements(files, 4);
            for i = 1:numel(files)
                testCase.verifyTrue(isfile(files(i)));
            end
        end

        function unknownObserverThrows(testCase)
            testCase.verifyError( ...
                @() prepareGenerators("bogus_obs", "D65", "A", ...
                    DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:UnknownObserver');
        end

        function unknownIlluminantThrows(testCase)
            testCase.verifyError( ...
                @() prepareGenerators("1931_2deg", "D65", "BogusIllum", ...
                    DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:UnknownIlluminant');
        end

        function customIlluminantCsv(testCase)
            csvFile = fullfile(testCase.OutputDir, "my_led_panel.csv");
            wl = (380:780)';
            spd = ones(size(wl));
            writematrix([wl, spd], csvFile);

            files = prepareGenerators("1931_2deg", "D65", csvFile, ...
                Spacing=10, Refl=0.5, ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            % A flat SPD of ones leaves k2 times the binned 1931 CMFs.
            cmf = readmatrix(fullfile(testCase.DataDir, "CIE_xyz_1931_2deg.csv"));
            cmf = cmf(cmf(:, 1) >= 380 & cmf(:, 1) <= 779, 2:4);
            data = readmatrix(files(1), CommentStyle="%");
            k = testCase.headerScale(string(fileread(files(1))));
            testCase.verifyEqual(data(:, 5:7), k(2) * testCase.binSums(cmf, 10), ...
                "RelTol", 1e-12);
        end

        % Custom observer CSV

        function customObserverMatchesNamedObserver(testCase)
            % The supplied 1931 2-degree table, imported through the custom
            % route, must produce the same numbers as the named route.
            csvFile = testCase.writeObserverCsv("cie_copy.csv", ...
                readmatrix(fullfile(testCase.DataDir, "CIE_xyz_1931_2deg.csv")));

            named = prepareGenerators("1931_2deg", "D65", "A", Spacing=10, ...
                Refl=0.5, DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            custom = prepareGenerators(csvFile, "D65", "A", Spacing=10, ...
                Refl=0.5, ObserverNorm="white_y100", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);

            testCase.verifyEqual(testCase.payloadHash(custom(1)), ...
                testCase.payloadHash(named(1)));
            testCase.verifyEqual(readmatrix(custom(1), CommentStyle="%"), ...
                readmatrix(named(1), CommentStyle="%"));
        end

        function customObserverAsSuppliedKeepsChannelValues(testCase)
            % as_supplied applies no white anchor, so k1 and k2 stay at 1
            % and the generators are the raw channel-times-SPD sums.
            wl = (380:780)';
            cmf = [ones(size(wl)), 2*ones(size(wl)), 3*ones(size(wl))];
            csvFile = testCase.writeObserverCsv("flat.csv", [wl, cmf]);

            files = prepareGenerators(csvFile, "E", "E", Spacing=10, ...
                Refl=0.5, ObserverNorm="as_supplied", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            content = string(fileread(files(1)));
            testCase.verifySubstring(content, "as_supplied");
            testCase.verifyEqual(testCase.headerScale(content), [1 1]);

            raw = readmatrix(files(1), CommentStyle="%");
            % Ten 1 nm samples per bin, each channel constant.
            testCase.verifyEqual(raw(1, 2:4), [10 20 30], "AbsTol", 1e-9);
        end

        function customObserverAcceptsNegativeValues(testCase)
            % Color-matching functions are signed. A negative lobe is valid.
            wl = (380:780)';
            cmf = [sin((wl - 380) / 40), ones(size(wl)), cos((wl - 380) / 40)];
            csvFile = testCase.writeObserverCsv("signed.csv", [wl, cmf]);
            files = prepareGenerators(csvFile, "D65", "A", Spacing=10, ...
                Refl=0.5, ObserverNorm="as_supplied", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyTrue(isfile(files(1)));
            testCase.verifyTrue(any(readmatrix(files(1), CommentStyle="%") < 0, "all"));
        end

        function customObserverRecordsItsIdentity(testCase)
            wl = (380:780)';
            csvFile = testCase.writeObserverCsv("my_camera.csv", ...
                [wl, ones(numel(wl), 3)]);
            files = prepareGenerators(csvFile, "D65", "A", Spacing=10, ...
                Refl=0.5, ObserverNorm="white_y100", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            content = string(fileread(files(1)));

            testCase.verifySubstring(content, "User-supplied observer");
            testCase.verifySubstring(content, "Source file: " + csvFile);
            testCase.verifySubstring(content, "Source SHA-256: " + ...
                testCase.sha256OfFile(csvFile));
            testCase.verifySubstring(content, "observer=my_camera");
            % No borrowed identity or license for user data.
            testCase.verifyFalse(contains(extractBetween(content, ...
                "% Observer:", "% Illuminant 1:"), "doi.org"));
        end

        function customObserverNameIsFilenameSafe(testCase)
            wl = (380:780)';
            csvFile = testCase.writeObserverCsv("odd name-2.csv", ...
                [wl, ones(numel(wl), 3)]);
            files = prepareGenerators(csvFile, "D65", "A", Spacing=10, ...
                Refl=0.5, ObserverNorm="as_supplied", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            [~, base] = fileparts(files(1));
            testCase.verifyTrue(startsWith(base, "generators_oddName_2_D65_A_"));
            % A path must never reach a dataset identifier.
            testCase.verifyFalse(contains(base, filesep));
            testCase.verifyFalse(contains(base, ".csv"));
        end

        function customObserverResolvesPathFromAnotherFolder(testCase)
            % The launcher runs the run definition from a private preparation
            % directory, so a path relative to the software root must resolve.
            wl = (380:780)';
            rel = fullfile("tests", "tmp_launcher_observer.csv");
            repoRoot = fileparts(fileparts(mfilename("fullpath")));
            abs = fullfile(repoRoot, rel);
            writematrix([wl, ones(numel(wl), 3)], abs);
            restore = onCleanup(@() delete(abs));

            elsewhere = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            back = cd(elsewhere);
            restoreCd = onCleanup(@() cd(back));

            files = prepareGenerators(rel, "D65", "A", Spacing=10, Refl=0.5, ...
                ObserverNorm="as_supplied", DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir);
            testCase.verifyTrue(isfile(files(1)));
            testCase.verifySubstring(string(fileread(files(1))), ...
                "observer=tmp_launcher_observer");
        end

        function customObserverNeedsExplicitNormalization(testCase)
            wl = (380:780)';
            csvFile = testCase.writeObserverCsv("nonorm.csv", ...
                [wl, ones(numel(wl), 3)]);
            testCase.verifyError(@() prepareGenerators(csvFile, "D65", "A", ...
                Spacing=10, DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir), ...
                'prepareGenerators:ObserverNormRequired');
        end

        function observerNormRejectedForNamedObserver(testCase)
            testCase.verifyError(@() prepareGenerators("1931_2deg", "D65", "A", ...
                Spacing=10, ObserverNorm="white_y100", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:ObserverNormNotApplicable');
        end

        function malformedCustomObserverThrows(testCase)
            wl = (380:780)';
            good = [wl, ones(numel(wl), 3)];

            bad = struct( ...
                'threeColumns',  {[wl, ones(numel(wl), 2)]}, ...
                'fiveColumns',   {[wl, ones(numel(wl), 4)]}, ...
                'notFinite',     {testCase.withValue(good, 5, 2, Inf)}, ...
                'missingValue',  {testCase.withValue(good, 7, 3, NaN)}, ...
                'outOfOrder',    {good([2 1 3:end], :)}, ...
                'duplicateWl',   {good([1 1 2:end], :)}, ...
                'allZero',       {[wl, zeros(numel(wl), 3)]}, ...
                'oneRow',        {good(1, :)});

            for f = string(fieldnames(bad))'
                csvFile = testCase.writeObserverCsv(f + ".csv", bad.(f));
                testCase.verifyError(@() prepareGenerators(csvFile, "D65", "A", ...
                    Spacing=10, ObserverNorm="as_supplied", ...
                    DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                    'prepareGenerators:BadObserverFile', ...
                    "expected a clear error for " + f);
            end
        end

        function missingCustomObserverFileThrows(testCase)
            testCase.verifyError(@() prepareGenerators("no_such_observer.csv", ...
                "D65", "A", Spacing=10, ObserverNorm="as_supplied", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:FileNotFound');
        end

        function customObserverWithoutOverlapThrows(testCase)
            % A table that does not reach the requested range cannot produce
            % a single bin.
            wl = (900:1000)';
            csvFile = testCase.writeObserverCsv("infrared.csv", ...
                [wl, ones(numel(wl), 3)]);
            testCase.verifyError(@() prepareGenerators(csvFile, "D65", "A", ...
                Spacing=10, ObserverNorm="as_supplied", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:NoSpectralOverlap');
        end

        % Spectrum targets must match the discrete generators

        function constantSpectrumMatchesReflForEachObserver(testCase)
            % A flat spectrum at level r must give exactly the target that
            % Refl=r gives, for every observer family and normalization.
            cie = readmatrix(fullfile(testCase.DataDir, "CIE_xyz_1931_2deg.csv"));
            cie(isnan(cie)) = 0;
            custom = testCase.writeObserverCsv("obs_xyz.csv", cie);

            cases = { ...
                {"1931_2deg", {}}, ...
                {"lms_2deg",  {}}, ...
                {custom, {"ObserverNorm", "white_y100"}}, ...
                {custom, {"ObserverNorm", "as_supplied"}}};

            for spacing = [1 10 7]
                for c = cases
                    obs = c{1}{1}; extra = c{1}{2};
                    r = 0.4;
                    spec = testCase.writeSpectrumCsv( ...
                        sprintf("flat_%d.csv", spacing), (300:900)', r);
                    common = {"Spacing", spacing, "DataDir", testCase.DataDir, ...
                        "OutputDir", testCase.OutputDir};

                    byRefl = prepareGenerators(obs, "D65", "A", ...
                        common{:}, "Refl", r, extra{:});
                    bySpec = prepareGenerators(obs, "D65", "A", ...
                        common{:}, "Spectrum", spec, extra{:});

                    label = sprintf("%s at %d nm", obs, spacing);
                    testCase.verifyEqual(testCase.targetOf(bySpec(1)), ...
                        testCase.targetOf(byRefl(1)), ...
                        "constant spectrum differs from Refl for " + label, ...
                        "RelTol", 1e-12);
                    % The generators themselves must be untouched by the route.
                    testCase.verifyEqual(readmatrix(bySpec(1), CommentStyle="%"), ...
                        readmatrix(byRefl(1), CommentStyle="%"), ...
                        "generators changed for " + label);
                end
            end
        end

        function constantSpectrumMatchesReflAcrossIlluminantRanges(testCase)
            % Illuminant 2 is narrower than illuminant 1 here, so the
            % retained range is set by the pair, not by illuminant 1 alone.
            narrow = fullfile(testCase.OutputDir, "narrow_illum.csv");
            wl = (400:700)';
            writematrix([wl, ones(size(wl))], narrow);
            spec = testCase.writeSpectrumCsv("flat_range.csv", (300:900)', 0.25);

            byRefl = prepareGenerators("1931_2deg", "D65", narrow, ...
                Spacing=10, Refl=0.25, DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir);
            bySpec = prepareGenerators("1931_2deg", "D65", narrow, ...
                Spacing=10, Spectrum=spec, DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir);
            testCase.verifyEqual(testCase.targetOf(bySpec(1)), ...
                testCase.targetOf(byRefl(1)), "RelTol", 1e-12);
        end

        function spectrumIgnoresSamplesDroppedByBinning(testCase)
            % 380 to 780 is 401 samples. At 10 nm only 400 are retained, so
            % a spectrum that differs only at the dropped final sample must
            % give the same target.
            wl = (300:900)';
            a = testCase.writeSpectrumCsv("drop_a.csv", wl, 0.5);
            b = fullfile(testCase.OutputDir, "drop_b.csv");
            refl = 0.5 * ones(size(wl));
            refl(wl == 780) = 0.9;
            writematrix([wl, refl], b);

            fa = prepareGenerators("1931_2deg", "D65", "A", Spacing=10, ...
                Spectrum=a, DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            fb = prepareGenerators("1931_2deg", "D65", "A", Spacing=10, ...
                Spectrum=b, DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyEqual(testCase.targetOf(fb(1)), ...
                testCase.targetOf(fa(1)), "RelTol", 1e-12);
        end

        function varyingSpectrumMatchesBandAverageCalculation(testCase)
            % Recompute the documented calculation independently. Interpolate
            % onto the retained 1 nm grid, average within each band, then
            % apply the normalized first-mechanism generators.
            wl = (300:900)';
            refl = 0.5 + 0.4 * sin((wl - 300) / 53);
            spec = fullfile(testCase.OutputDir, "varying.csv");
            writematrix([wl, refl], spec);

            spacing = 10;
            files = prepareGenerators("1931_2deg", "D65", "A", ...
                Spacing=spacing, Spectrum=spec, DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir);
            data = readmatrix(files(1), CommentStyle="%");
            g1 = data(:, 2:4)';
            nBins = size(g1, 2);

            % The retained 1 nm grid is nBins complete bands ending at the
            % last retained sample, centered on the reported bin wavelengths.
            centers = data(:, 1);
            first = centers(1) - (spacing - 1) / 2;
            kept = (first:(first + nBins * spacing - 1))';
            rho = mean(reshape(interp1(wl, refl, kept, "linear"), spacing, nBins), 1)';

            testCase.verifyEqual(testCase.targetOf(files(1)), g1 * rho, ...
                "RelTol", 1e-10);
            % A varying spectrum must not coincide with the flat-0.5 target.
            flat = prepareGenerators("1931_2deg", "D65", "A", Spacing=spacing, ...
                Refl=0.5, DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyNotEqual(testCase.targetOf(files(1)), ...
                testCase.targetOf(flat(1)));
        end

        function spectrumMustCoverRetainedRange(testCase)
            spec = testCase.writeSpectrumCsv("short.csv", (500:600)', 0.5);
            testCase.verifyError(@() prepareGenerators("1931_2deg", "D65", "A", ...
                Spacing=10, Spectrum=spec, DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir), ...
                'prepareGenerators:SpectrumRange');
        end

        function malformedSpectrumThrows(testCase)
            wl = (300:900)';
            good = [wl, 0.5 * ones(size(wl))];
            bad = struct( ...
                'oneColumn',   {wl}, ...
                'threeColumns',{[wl, 0.5*ones(numel(wl), 2)]}, ...
                'notFinite',   {testCase.withValue(good, 4, 2, NaN)}, ...
                'outOfOrder',  {good([2 1 3:end], :)}, ...
                'duplicateWl', {good([1 1 2:end], :)});
            for f = string(fieldnames(bad))'
                spec = fullfile(testCase.OutputDir, f + "_spec.csv");
                writematrix(bad.(f), spec);
                testCase.verifyError(@() prepareGenerators("1931_2deg", "D65", ...
                    "A", Spacing=10, Spectrum=spec, DataDir=testCase.DataDir, ...
                    OutputDir=testCase.OutputDir), ...
                    'prepareGenerators:BadSpectrumFile', ...
                    "expected a clear error for " + f);
            end
        end

        function explicitZ0IsUnchangedBySpectrumHandling(testCase)
            z0 = [48.5; 50.1; 43.2];
            files = prepareGenerators("1931_2deg", "D65", "A", Spacing=10, ...
                Z0=z0, DataDir=testCase.DataDir, OutputDir=testCase.OutputDir);
            testCase.verifyEqual(testCase.targetOf(files(1)), z0, "AbsTol", 1e-9);
            testCase.verifySubstring(string(fileread(files(1))), "explicit z0");
        end

        % White normalization must be defined before it is used

        function zeroSecondChannelRejectsWhiteNormalization(testCase)
            wl = (380:780)';
            cmf = [ones(size(wl)), zeros(size(wl)), ones(size(wl))];
            spec = testCase.writeObserverCsv("zero_mid.csv", [wl, cmf]);
            testCase.verifyError(@() prepareGenerators(spec, "D65", "A", ...
                Spacing=10, ObserverNorm="white_y100", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:UndefinedWhiteNormalization');
        end

        function cancelingSignedSecondChannelRejectsWhiteNormalization(testCase)
            % Non-zero signed values whose white response cancels exactly.
            wl = (380:780)';
            mid = ones(size(wl));
            mid(wl > 580) = -1;
            mid(wl == 580) = 0;
            % 200 samples at +1, 200 at -1 and one at 0. The white response
            % cancels exactly while the channel is far from being all zero.
            spec = testCase.writeObserverCsv("cancel_mid.csv", ...
                [wl, ones(size(wl)), mid, ones(size(wl))]);
            testCase.verifyError(@() prepareGenerators(spec, "E", "E", ...
                Spacing=1, ObserverNorm="white_y100", ...
                DataDir=testCase.DataDir, OutputDir=testCase.OutputDir), ...
                'prepareGenerators:UndefinedWhiteNormalization');
        end

        function signedChannelsWithDefinedWhiteAreAccepted(testCase)
            % Signed values are legitimate. Only an undefined denominator is
            % rejected, so this must succeed and anchor the white point.
            wl = (380:780)';
            ch1 = sin((wl - 380) / 40);
            ch3 = cos((wl - 380) / 40);
            spec = testCase.writeObserverCsv("signed_ok.csv", ...
                [wl, ch1, ones(size(wl)), ch3]);
            files = prepareGenerators(spec, "D65", "A", Spacing=10, ...
                ObserverNorm="white_y100", DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir);
            data = readmatrix(files(1), CommentStyle="%");
            testCase.verifyTrue(all(isfinite(data), "all"));
            testCase.verifyTrue(any(data(:, 2) < 0));
            % A perfect reflector reads 100 in the second channel.
            testCase.verifyEqual(sum(data(:, 3)), 100, "RelTol", 1e-10);
        end

        function unscaledModeKeepsSuppliedValuesWithZeroWhite(testCase)
            % as_supplied applies no white anchor, so a zero white response
            % is not an error there.
            wl = (380:780)';
            cmf = [ones(size(wl)), zeros(size(wl)), 2*ones(size(wl))];
            spec = testCase.writeObserverCsv("zero_mid_ok.csv", [wl, cmf]);
            files = prepareGenerators(spec, "E", "E", Spacing=10, ...
                ObserverNorm="as_supplied", DataDir=testCase.DataDir, ...
                OutputDir=testCase.OutputDir);
            data = readmatrix(files(1), CommentStyle="%");
            testCase.verifyEqual(data(1, 2:4), [10 0 20], "AbsTol", 1e-9);
            testCase.verifyEqual(testCase.headerScale( ...
                string(fileread(files(1)))), [1 1]);
        end
    end

    methods (Access = private)
        function verifyGeneratorPayload(testCase, file, nBins)
            data = readmatrix(file, CommentStyle="%");
            testCase.verifySize(data, [nBins 7]);
            testCase.verifyTrue(all(isfinite(data), "all"));
            testCase.verifyTrue(all(any(data(:, 2:7) ~= 0, 1)), ...
                "a generator channel is all zero");
        end

        function sums = binSums(~, values, spacing)
            % Sum consecutive rows of a 1 nm table into bands of spacing rows.
            nBins = size(values, 1) / spacing;
            sums = squeeze(sum(reshape(values, spacing, nBins, []), 1));
        end

        function path = writeSpectrumCsv(testCase, name, wl, level)
            path = fullfile(testCase.OutputDir, name);
            writematrix([wl, level * ones(size(wl))], path);
        end

        function z0 = targetOf(~, file)
            % The payload carries z0 at full precision, on the line after the
            % band count, which follows the payload hash line.
            lines = splitlines(string(fileread(file)));
            k = find(startsWith(lines, "% payload_sha256="), 1);
            z0 = sscanf(lines(k + 2), "%f");
        end

        function path = writeObserverCsv(testCase, name, data)
            path = fullfile(testCase.OutputDir, name);
            writematrix(data, path);
        end

        function data = withValue(~, data, row, col, value)
            data(row, col) = value;
        end

        function h = payloadHash(~, file)
            h = string(extractBetween(string(fileread(file)), ...
                "payload_sha256=", newline));
        end

        function k = headerScale(~, content)
            k = double(string(extractBetween(content, "k1=", ", k2=")));
            k(2) = double(string(extractBetween(content, "k2=", " (")));
        end

        function hex = sha256OfFile(~, path)
            fid = fopen(path, "r");
            c = onCleanup(@() fclose(fid));
            md = java.security.MessageDigest.getInstance("SHA-256");
            while true
                buf = fread(fid, 1048576, "*uint8");
                if isempty(buf), break; end
                md.update(buf);
            end
            hex = lower(string(reshape(dec2hex(typecast(md.digest(), "uint8"))', 1, [])));
        end
    end
end
