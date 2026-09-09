classdef validateAllMMBTest < matlab.unittest.TestCase
% VALIDATEALLMMBTEST  Geometric validity tests over every dataset.
%
%   Parameterized version of validateMMBTest that runs the geometric checks
%   against every dataset in runs_output/. Each dataset becomes a separate test
%   instance with the same 5 verification methods, so a failure on one dataset
%   does not block the others from running.
%
%   The class discovers datasets from the output directory
%   (default: ../runs_output relative to this test file, override via the
%   MMB_RUNS_OUTPUT environment variable).
%
%   Run:
%       results = runtests("validateAllMMBTest");
%
%       % Or with a custom runs_output location:
%       setenv("MMB_RUNS_OUTPUT", "/path/to/runs_output");
%       results = runtests("validateAllMMBTest");
%
%       % Summarize failures by dataset:
%       failed = results([results.Failed]);
%       fprintf("Failed: %d of %d tests\n", numel(failed), numel(results));
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (ClassSetupParameter)
        % Parameterize over every dataset found when the suite is built.
        % MATLAB calls findDatasetIds() once when the test class is loaded, each
        % entry becomes a separate test instance.
        DatasetId = validateAllMMBTest.findDatasetIds()
    end

    properties (Access = private)
        Vertices double
        Faces double
        Volume double
        Center double
        ResultsDir string
    end

    methods (Static, Access = private)
        function datasetIds = findDatasetIds()
        % Discover every dataset with a complete set of result files. Called
        % once by the test framework before any tests run.
            runsOutput = getenv("MMB_RUNS_OUTPUT");
            if runsOutput == ""
                here = fileparts(mfilename("fullpath"));
                runsOutput = fullfile(here, "..", "runs_output");
            end

            if ~isfolder(runsOutput)
                warning("validateAllMMBTest:NoRunsOutput", ...
                    "runs_output not found at %s. No tests will be generated.", ...
                    runsOutput);
                datasetIds = {""};
                return;
            end

            entries = dir(runsOutput);
            entries = entries([entries.isdir] & ~ismember({entries.name}, {'.', '..'}));

            datasetIds = {};
            for k = 1:numel(entries)
                datasetId = entries(k).name;
                results = fullfile(runsOutput, datasetId, "results");
                v = fullfile(results, "mmb_" + datasetId + "_vertices.csv");
                f = fullfile(results, "mmb_" + datasetId + "_faces.csv");
                s = fullfile(results, "mmb_" + datasetId + "_summary.txt");
                if isfile(v) && isfile(f) && isfile(s)
                    datasetIds{end+1} = datasetId;  %#ok<AGROW>
                end
            end

            if isempty(datasetIds)
                warning("validateAllMMBTest:NoDatasets", ...
                    "No datasets with complete result files found in %s.", runsOutput);
                datasetIds = {""};
            end
        end
    end

    methods (TestClassSetup)
        function loadResults(testCase, DatasetId)
            testCase.assumeNotEqual(DatasetId, "", ...
                "No datasets discovered, skipping.");

            runsOutput = getenv("MMB_RUNS_OUTPUT");
            if runsOutput == ""
                here = fileparts(mfilename("fullpath"));
                runsOutput = fullfile(here, "..", "runs_output");
            end
            testCase.ResultsDir = string(fullfile(runsOutput, DatasetId, "results"));

            vertPath = fullfile(testCase.ResultsDir, "mmb_" + DatasetId + "_vertices.csv");
            facePath = fullfile(testCase.ResultsDir, "mmb_" + DatasetId + "_faces.csv");
            summaryPath = fullfile(testCase.ResultsDir, "mmb_" + DatasetId + "_summary.txt");

            testCase.Vertices = readmatrix(vertPath);
            testCase.Faces = readmatrix(facePath);

            summaryText = fileread(summaryPath);
            volMatch = regexp(summaryText, ...
                'Hull volume:\s+([\d.eE+-]+)', 'tokens');
            testCase.assumeNotEmpty(volMatch, ...
                "Hull volume field missing from summary for " + DatasetId);
            testCase.Volume = str2double(volMatch{1}{1});

            centerMatch = regexp(summaryText, ...
                'Center:\s+\[([\d.eE+-]+),\s*([\d.eE+-]+),\s*([\d.eE+-]+)\]', ...
                'tokens');
            testCase.assumeNotEmpty(centerMatch, ...
                "Center field missing from summary for " + DatasetId);
            testCase.Center = [str2double(centerMatch{1}{1}), ...
                               str2double(centerMatch{1}{2}), ...
                               str2double(centerMatch{1}{3})];
        end
    end

    methods (Test, TestTags = {'Integration'})
        function volumeCrossCheck(testCase)
        % Recompute hull volume from vertices. Must match summary file
            [~, vol] = convhulln(testCase.Vertices);
            testCase.verifyEqual(vol, testCase.Volume, ...
                "Recomputed hull volume must match summary file", RelTol=1e-6);
        end

        function directionalMaximaAppearInFaces(testCase)
        % Check that directional maxima of the stored vertices appear in the face list.
            rng(42);
            nDirs = 50;
            for i = 1:nDirs
                d = randn(1, 3);
                d = d / norm(d);
                projections = testCase.Vertices * d';
                [~, maxIdx] = max(projections);
                facesUsing = any(testCase.Faces == maxIdx, 2);
                testCase.verifyTrue(any(facesUsing), sprintf( ...
                    "Extreme vertex in direction %d must appear in a face", i));
            end
        end

        function randomInteriorPointTest(testCase)
        % Convex combinations of boundary vertices must lie inside hull
            rng(42);
            nTests = 100;
            nVerts = size(testCase.Vertices, 1);
            DT = delaunayTriangulation(testCase.Vertices);
            for i = 1:nTests
                idx = randperm(nVerts, min(4, nVerts));
                w = rand(numel(idx), 1);
                w = w / sum(w);
                pt = w' * testCase.Vertices(idx, :);
                tid = pointLocation(DT, pt);
                testCase.verifyFalse(isnan(tid), sprintf( ...
                    "Random interior point %d must be inside hull", i));
            end
        end

        function meshTopology(testCase)
        % Euler characteristic V - E + F = 2 for closed convex polyhedron
            V = size(testCase.Vertices, 1);
            F = size(testCase.Faces, 1);
            edges = sort([testCase.Faces(:,[1 2]); ...
                          testCase.Faces(:,[2 3]); ...
                          testCase.Faces(:,[1 3])], 2);
            E = size(unique(edges, 'rows'), 1);
            testCase.verifyEqual(V - E + F, 2, ...
                "Euler characteristic V-E+F must equal 2");
        end

        function sandwichBounds(testCase)
        % Check that the center lies in the hull and its volume and extents are positive.
            DT = delaunayTriangulation(testCase.Vertices);

            tid = pointLocation(DT, testCase.Center);
            testCase.verifyFalse(isnan(tid), ...
                "MMB center must be inside the hull");

            testCase.verifyGreaterThan(testCase.Volume, 0, ...
                "MMB volume must be positive");
            testCase.verifyTrue(isfinite(testCase.Volume), ...
                "MMB volume must be finite");

            bbox = max(testCase.Vertices) - min(testCase.Vertices);
            testCase.verifyTrue(all(isfinite(bbox) & bbox > 0), ...
                "Bounding box must be finite and non-degenerate");
        end
    end
end
