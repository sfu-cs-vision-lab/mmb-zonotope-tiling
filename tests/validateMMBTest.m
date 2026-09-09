classdef validateMMBTest < matlab.unittest.TestCase
% VALIDATEMMBTEST  Integration tests for MMB geometric validity
%
%   Verifies geometric properties of computed MMB results. Requires output
%   from a completed pipeline run (e.g., bash mmb_run.sh runs/runs_validate_10nm.m).
%   Tests are skipped if no results are found.
%
%   Run:
%       results = runtests("validateMMBTest");
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (ClassSetupParameter)
        ResultsDir = {"results"}
    end

    properties (Access = private)
        Vertices double
        Faces double
        Volume double
        Center double
        DatasetId string
    end

    methods (TestClassSetup)
        function loadResults(testCase, ResultsDir)
            vertFiles = dir(fullfile(ResultsDir, "mmb_*_vertices.csv"));
            testCase.assumeNotEmpty(vertFiles, ...
                "No MMB results found in " + ResultsDir + ...
                ". Run the pipeline first.");

            testCase.DatasetId = extractBefore(vertFiles(1).name, "_vertices.csv");
            testCase.Vertices = readmatrix(fullfile( ...
                ResultsDir, testCase.DatasetId + "_vertices.csv"));
            testCase.Faces = readmatrix(fullfile( ...
                ResultsDir, testCase.DatasetId + "_faces.csv"));

            summaryText = fileread(fullfile( ...
                ResultsDir, testCase.DatasetId + "_summary.txt"));
            volMatch = regexp(summaryText, ...
                'Hull volume:\s+([\d.eE+-]+)', 'tokens');
            testCase.Volume = str2double(volMatch{1}{1});

            centerMatch = regexp(summaryText, ...
                'Center:\s+\[([\d.eE+-]+),\s*([\d.eE+-]+),\s*([\d.eE+-]+)\]', ...
                'tokens');
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
