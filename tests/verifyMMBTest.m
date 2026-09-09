classdef verifyMMBTest < matlab.unittest.TestCase
% VERIFYMMBTEST  Tests for verifyMMB.
%
% Check input identity, file consistency, volume and sampled reflectance
% feasibility. Results from a different input must fail validation.
%
%   Uses the committed 10 nm D65 to A fixtures in tests/fixtures/, and
%   their rank 5, 4 and 3 forms, in which the second mechanism shares one,
%   two or all three channels with the first.
%
%   Run:
%       results = runtests("verifyMMBTest");
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (Access = private)
        FixDir string
        DatasetId string
        TmpDir string
    end

    properties (TestParameter)
        SensorRank = struct("Rank5", 5, "Rank4", 4, "Rank3", 3)
    end

    methods (TestMethodSetup)
        function locateFixtures(testCase)
            here = fileparts(mfilename("fullpath"));
            testCase.FixDir = fullfile(here, "fixtures");
            testCase.DatasetId = "1931_2deg_D65_A_10nm_refl50";
            testCase.assumeTrue(isfile(fullfile(testCase.FixDir, ...
                "generators_" + testCase.DatasetId + ".txt")), ...
                "fixtures not present");
            testCase.TmpDir = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
        end
    end

    methods (Test)
        function verifyPassesOnAnchorFixture(testCase)
            rep = verifyMMB(testCase.FixDir, ...
                fullfile(testCase.FixDir, "generators_" + testCase.DatasetId + ".txt"), ...
                Sample=48, Verbose=false);
            testCase.verifyTrue(rep.pass, strjoin(rep.reasons, " | "));
            testCase.verifyEqual(rep.lp.infeasible, 0);
            testCase.verifyLessThan(rep.volume.relDiff, 1e-10);
            testCase.verifyEqual(strlength(rep.sha.vertices), 64);
        end

        function internallyConsistentWrongProblemFails(testCase)
            % Relabel the refl50 results as refl90, including the summary
            % provenance. Every internal consistency check still agrees with
            % itself. Only the feasibility check against the refl90
            % generators can reject it.
            src = testCase.FixDir; dst = testCase.TmpDir;
            s50 = testCase.DatasetId; s90 = "1931_2deg_D65_A_10nm_refl90";
            copyfile(fullfile(src, "mmb_" + s50 + "_vertices.csv"), ...
                     fullfile(dst, "mmb_" + s90 + "_vertices.csv"));
            copyfile(fullfile(src, "mmb_" + s50 + "_faces.csv"), ...
                     fullfile(dst, "mmb_" + s90 + "_faces.csv"));
            % Forge the summary from real refl50 numbers, refl90 identity and a
            % z0 header line copied from the refl90 generators file so even the z0
            % cross-check is self-consistent.
            sTxt = string(fileread(fullfile(src, "mmb_" + s50 + "_summary.txt")));
            cd90 = string(fileread(fullfile(src, "generators_" + s90 + ".txt")));
            z0line90 = regexp(cd90, "% z0 = \[[^\]]+\]", "match", "once");
            sTxt = replace(sTxt, "generators_" + s50 + ".txt", "generators_" + s90 + ".txt");
            sTxt = regexprep(sTxt, "% z0 = \[[^\]]+\]", z0line90);
            fid = fopen(fullfile(dst, "mmb_" + s90 + "_summary.txt"), "w");
            fprintf(fid, "%s", sTxt); fclose(fid);

            rep = verifyMMB(dst, fullfile(src, "generators_" + s90 + ".txt"), ...
                Sample=32, Verbose=false);
            testCase.verifyFalse(rep.pass);
            testCase.verifyGreaterThan(rep.lp.indeterminate, 0, ...
                "Without a verified witness, the check must fail closed");
        end

        function tamperedVertexFails(testCase)
            src = testCase.FixDir; dst = testCase.TmpDir; s = testCase.DatasetId;
            V = readmatrix(fullfile(src, "mmb_" + s + "_vertices.csv"), FileType="text");
            V(7, :) = V(7, :) * 1.01;   % push one vertex outside the body
            fid = fopen(fullfile(dst, "mmb_" + s + "_vertices.csv"), "w");
            fprintf(fid, "%.17g,%.17g,%.17g\n", V'); fclose(fid);
            copyfile(fullfile(src, "mmb_" + s + "_faces.csv"), dst);
            copyfile(fullfile(src, "mmb_" + s + "_summary.txt"), dst);

            rep = verifyMMB(dst, fullfile(src, "generators_" + s + ".txt"), ...
                Sample=Inf, Verbose=false);
            testCase.verifyFalse(rep.pass);
            % caught by volume recompute, LP infeasibility of row 7 or both
            testCase.verifyTrue(any(contains(rep.reasons, "VOLUME")) || ...
                any(contains(rep.reasons, "FEASIBILITY")));
        end

        function partialBrandFails(testCase)
            src = testCase.FixDir; dst = testCase.TmpDir; s = testCase.DatasetId;
            copyfile(fullfile(src, "mmb_" + s + "_vertices.csv"), dst);
            copyfile(fullfile(src, "mmb_" + s + "_faces.csv"), dst);
            sTxt = string(fileread(fullfile(src, "mmb_" + s + "_summary.txt")));
            sTxt = "% PARTIAL: hulled from an INCOMPLETE chunk set (AllowPartial). NOT release data." ...
                + newline + sTxt;
            fid = fopen(fullfile(dst, "mmb_" + s + "_summary.txt"), "w");
            fprintf(fid, "%s", sTxt); fclose(fid);

            rep = verifyMMB(dst, fullfile(src, "generators_" + s + ".txt"), ...
                Sample=8, Verbose=false);
            testCase.verifyFalse(rep.pass);
            testCase.verifyTrue(any(contains(rep.reasons, "PARTIAL")));
        end

        function missingResultFilesFail(testCase)
            rep = verifyMMB(testCase.TmpDir, ...
                fullfile(testCase.FixDir, "generators_" + testCase.DatasetId + ".txt"), ...
                Sample=8, Verbose=false);
            testCase.verifyFalse(rep.pass);
            testCase.verifyTrue(any(contains(rep.reasons, "missing file")));
        end

        function flatBodyPasses(testCase, SensorRank)
            [resultsDir, genFile] = testCase.flatResult(SensorRank);
            rep = verifyMMB(resultsDir, genFile, Sample=Inf, Verbose=false);
            testCase.verifyTrue(rep.pass, strjoin(rep.reasons, " | "));
            testCase.verifyTrue(rep.volume.flat);
            testCase.verifyEqual(rep.volume.rank, SensorRank);
            testCase.verifyEqual(rep.volume.dimension, SensorRank - 3);
            testCase.verifyEqual(rep.volume.recomputed, 0);
        end

        function flatBodyOutOfItsPlaneFails(testCase)
            [resultsDir, genFile] = testCase.flatResult(5);
            vPath = fullfile(resultsDir, "mmb_" + testCase.DatasetId + "_rank5_vertices.csv");
            V = readmatrix(vPath, FileType="text");
            V(1, 1) = V(1, 1) + 1;   % off the plane of the shared channel
            fid = fopen(vPath, "w");
            fprintf(fid, "%.17g,%.17g,%.17g\n", V'); fclose(fid);
            rep = verifyMMB(resultsDir, genFile, Sample=8, Verbose=false);
            testCase.verifyFalse(rep.pass);
            testCase.verifyTrue(any(contains(rep.reasons, "Sensor rank 5 allows at most 2")));
        end

        function rankBelowSixWithoutFlatLineFails(testCase)
            [resultsDir, genFile] = testCase.flatResult(5);
            sPath = fullfile(resultsDir, "mmb_" + testCase.DatasetId + "_rank5_summary.txt");
            lines = readlines(sPath);
            writelines(lines(~startsWith(lines, "Flat body:")), sPath);
            rep = verifyMMB(resultsDir, genFile, Sample=8, Verbose=false);
            testCase.verifyFalse(rep.pass);
            testCase.verifyTrue(any(contains(rep.reasons, "no 'Flat body:' line")));
        end

        function countMismatchFails(testCase)
            src = testCase.FixDir; dst = testCase.TmpDir; s = testCase.DatasetId;
            V = readmatrix(fullfile(src, "mmb_" + s + "_vertices.csv"), FileType="text");
            fid = fopen(fullfile(dst, "mmb_" + s + "_vertices.csv"), "w");
            fprintf(fid, "%.17g,%.17g,%.17g\n", V(1:end-5, :)');  % drop 5 rows
            fclose(fid);
            copyfile(fullfile(src, "mmb_" + s + "_faces.csv"), dst);
            copyfile(fullfile(src, "mmb_" + s + "_summary.txt"), dst);
            rep = verifyMMB(dst, fullfile(src, "generators_" + s + ".txt"), ...
                Sample=8, Verbose=false);
            testCase.verifyFalse(rep.pass);
            testCase.verifyTrue(any(contains(rep.reasons, "INTEGRITY")));
        end
    end

    methods (Access = private)
        function [resultsDir, genFile] = flatResult(testCase, sensorRank)
            % FLATRESULT  Hull of the rank 5, 4 or 3 reference body
            %
            %   The points are tests/fixtures/reference_<id>_rank<r>.txt, the
            %   body of generators_<id>_rank<r>.txt, written in the kernel's
            %   format.
            id = testCase.DatasetId + "_rank" + sensorRank;
            genFile = fullfile(testCase.FixDir, "generators_" + id + ".txt");
            points = readmatrix(fullfile(testCase.FixDir, "reference_" + id + ".txt"), ...
                FileType="text", CommentStyle="%");
            kernelFile = fullfile(testCase.TmpDir, "mmb_" + id + ".txt");
            fid = fopen(kernelFile, "w");
            fprintf(fid, "%% Input: %s\n", genFile);
            fprintf(fid, "%% n=40, tiles_total=1, tiles_tested=1, tiles_intersecting=1, vertices=%d\n", ...
                size(points, 1));
            fprintf(fid, "%.17g %.17g %.17g\n", points');
            fprintf(fid, "%% complete vertices=%d\n", size(points, 1));
            fclose(fid);
            resultsDir = fullfile(testCase.TmpDir, "results");
            hullMMB(kernelFile, OutputDir=resultsDir, Verbose=false);
        end
    end
end
