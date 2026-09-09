classdef hullMMBTest < matlab.unittest.TestCase
% HULLMMBTEST  Tests for hullMMB
%
%   Covers the numeric core (hull, volume and deduplication), flat bodies,
%   the input checks and self-verification of the written output. The input
%   checks are content-verified inputs, chunk-set completeness and refusal of
%   data belonging to another dataset or truncated data.
%
%   Run:
%       results = runtests("hullMMBTest");
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (Access = private)
        OutputDir string
    end

    properties (TestParameter)
        % FlatCase  Bodies in tests/fixtures/reference_<FlatCase>.txt. Rank 5
        % is a polygon and rank 4 a segment, from an independent zonotope
        % tiling, and rank 3 is the target point
        FlatCase = {"1931_2deg_D65_A_10nm_refl50_rank5", "1931_2deg_D65_A_10nm_refl50_rank4", ...
            "1931_2deg_D65_A_10nm_refl50_rank3"}
    end

    methods (TestMethodSetup)
        function createOutputDir(testCase)
            testCase.OutputDir = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
        end
    end

    methods (Test)
        function cubeProducesCorrectHull(testCase)
            verts = [0 0 0; 1 0 0; 0 1 0; 0 0 1; ...
                     1 1 0; 1 0 1; 0 1 1; 1 1 1];
            vfile = testCase.writeTempVertexFile(verts, "cube");

            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyEqual(mmb.nVertices, 8);
            testCase.verifyEqual(mmb.nFaces, 12);
            testCase.verifyEqual(mmb.hullVolume, 1.0, RelTol=1e-10);
        end

        function cubeTrueFacesAreSix(testCase)
            % Merge the cube triangles into six square faces, keeping opposite faces separate.
            verts = 0.5 * [-1 -1 -1; 1 -1 -1; -1 1 -1; -1 -1 1; ...
                            1 1 -1; 1 -1 1; -1 1 1; 1 1 1];
            vfile = testCase.writeTempVertexFile(verts, "cube_ctr");
            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyEqual(mmb.trueFaceCount, 6, ...
                "origin-centered cube: opposite faces have equal |offset| and antiparallel normals. They must not merge");
        end

        function outputFilesCreated(testCase)
            verts = [0 0 0; 1 0 0; 0 1 0; 0 0 1; 1 1 1];
            vfile = testCase.writeTempVertexFile(verts, "tetra");

            hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);

            [~, datasetId] = fileparts(vfile);
            testCase.verifyTrue(isfile(fullfile( ...
                testCase.OutputDir, datasetId + "_vertices.csv")));
            testCase.verifyTrue(isfile(fullfile( ...
                testCase.OutputDir, datasetId + "_faces.csv")));
            testCase.verifyTrue(isfile(fullfile( ...
                testCase.OutputDir, datasetId + "_summary.txt")));
        end

        function verticesCsvRoundTripsExactly(testCase)
            % %.17g output must round-trip doubles bit-exactly
            rng(7);
            verts = [randn(40, 3) * pi; eye(3); 0 0 0];
            vfile = testCase.writeTempVertexFile(verts, "roundtrip");
            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            csvVerts = readmatrix(fullfile( ...
                testCase.OutputDir, "mmb_roundtrip_vertices.csv"), FileType="text");
            testCase.verifyEqual(csvVerts, mmb.vertices);   % bitwise
        end

        function facesCsvFormat(testCase)
            verts = [0 0 0; 1 0 0; 0 1 0; 0 0 1; 1 1 1];
            vfile = testCase.writeTempVertexFile(verts, "format_f");

            hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);

            csvFaces = readmatrix(fullfile( ...
                testCase.OutputDir, "mmb_format_f_faces.csv"));
            testCase.verifyEqual(size(csvFaces, 2), 3);
            testCase.verifyGreaterThanOrEqual(min(csvFaces(:)), 1);
        end

        function multipleFiles(testCase)
            v1 = [0 0 0; 1 0 0; 0 1 0; 0 0 1; 1 1 1];
            v2 = [0 0 0; 2 0 0; 0 2 0; 0 0 2; 2 2 2];
            f1 = testCase.writeTempVertexFile(v1, "multi1");
            f2 = testCase.writeTempVertexFile(v2, "multi2");

            mmb = hullMMB([f1, f2], OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyNumElements(mmb, 2);
            testCase.verifyGreaterThan(mmb(2).hullVolume, mmb(1).hullVolume);
        end

        function deduplicationRemovesDuplicates(testCase)
            verts = [0 0 0; 1 0 0; 0 1 0; 0 0 1; 1 1 1; ...
                     0 0 0; 1 0 0; 0 1 0];
            vfile = testCase.writeTempVertexFile(verts, "dedup");

            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyLessThan(mmb.nVertices, size(verts, 1));
        end

        function nonFiniteRowsRemovedAndCounted(testCase)
            verts = [0 0 0; 1 0 0; 0 1 0; 0 0 1; 1 1 1; NaN 0 0; Inf 1 1];
            vfile = testCase.writeTempVertexFile(verts, "nanrows");
            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyEqual(mmb.nNonFinite, 2);
            testCase.verifyEqual(mmb.hullVolume, 0.5, RelTol=1e-10);
        end

        function flatBodyHasVolumeZeroAndNoFaces(testCase, FlatCase)
            % Each point appears twice, so the vertices must be the
            % distinct points
            ref = fullfile(fileparts(mfilename("fullpath")), "fixtures", ...
                "reference_" + FlatCase + ".txt");
            points = readmatrix(ref, FileType="text", CommentStyle="%");
            vfile = testCase.writeTempVertexFile([points; points], FlatCase);
            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyEqual(mmb.hullVolume, 0);
            testCase.verifyEqual(mmb.nFaces, 0);
            testCase.verifyEqual(mmb.vertices, uniquetol(points, 1e-8, ByRows=true));
            faces = dir(fullfile(testCase.OutputDir, "mmb_" + FlatCase + "_faces.csv"));
            testCase.verifyEqual(faces.bytes, 0);
            s = fileread(fullfile(testCase.OutputDir, "mmb_" + FlatCase + "_summary.txt"));
            testCase.verifySubstring(s, "Flat body:");
            testCase.verifySubstring(s, "Hull volume:       0.000000000000000e+00");
        end

        function thinBoxIsNotFlat(testCase)
            % 1e-6 thick against a largest coordinate of 1, above 1e-8
            verts = [0 0 0; 1 0 0; 0 1 0; 1 1 0];
            verts = [verts; verts + [0 0 1e-6]];
            vfile = testCase.writeTempVertexFile(verts, "thin");
            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyEqual(mmb.nFaces, 12);
            testCase.verifyEqual(mmb.hullVolume, 1e-6, RelTol=1e-9);
        end

        % Input validation

        function wrongProvenanceRefused(testCase)
            verts = eye(4, 3);
            vfile = testCase.writeTempVertexFile(verts, "claimed", ...
                InputDatasetId="actually_other");
            testCase.verifyError(@() hullMMB(vfile, ...
                OutputDir=testCase.OutputDir, Verbose=false), ...
                "hullMMB:wrongProvenance");
        end

        function missingProvenanceRefused(testCase)
            vfile = fullfile(testCase.OutputDir, "mmb_noprov.txt");
            fid = fopen(vfile, 'w');
            fprintf(fid, "%% n=10, vertices=4\n");
            fprintf(fid, "%.17g %.17g %.17g\n", eye(4, 3)');
            fclose(fid);
            testCase.verifyError(@() hullMMB(vfile, ...
                OutputDir=testCase.OutputDir, Verbose=false), ...
                "hullMMB:noProvenance");
        end

        function expectDatasetIdRefusesAliens(testCase)
            vfile = testCase.writeTempVertexFile(eye(4, 3), "some_dataset");
            testCase.verifyError(@() hullMMB(vfile, ...
                ExpectDatasetID="different_dataset", ...
                OutputDir=testCase.OutputDir, Verbose=false), ...
                "hullMMB:alienDatasetId");
        end

        function truncatedInputRefused(testCase)
            % header promises more rows than the file contains
            vfile = testCase.writeTempVertexFile(eye(4, 3), "trunc", ...
                ClaimVertices=9);
            testCase.verifyError(@() hullMMB(vfile, ...
                OutputDir=testCase.OutputDir, Verbose=false), ...
                "hullMMB:truncatedInput");
        end

        function incompleteChunkSetRefused(testCase)
            f1 = testCase.writeTempVertexFile(eye(4, 3), "ic", ...
                Chunk=1, NChunks=3);
            testCase.verifyError(@() hullMMB(f1, ...
                OutputDir=testCase.OutputDir, Verbose=false), ...
                "hullMMB:incompleteChunkSet");
        end

        function completeChunkSetMerges(testCase)
            v1 = [0 0 0; 1 0 0; 0 1 0; 0 0 1];
            v2 = [1 1 0; 1 0 1; 0 1 1; 1 1 1];
            f1 = testCase.writeTempVertexFile(v1, "cc", Chunk=0, NChunks=2);
            f2 = testCase.writeTempVertexFile(v2, "cc", Chunk=1, NChunks=2);
            mmb = hullMMB([f1, f2], OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyNumElements(mmb, 1);
            testCase.verifyEqual(mmb.nVertices, 8);
            testCase.verifyEqual(mmb.hullVolume, 1.0, RelTol=1e-10);
        end

        function allowPartialBrandsSummary(testCase)
            f1 = testCase.writeTempVertexFile(eye(4, 3), "part", ...
                Chunk=1, NChunks=3);
            w = warning('off', 'hullMMB:partialSet');
            cleanupObj = onCleanup(@() warning(w));
            mmb = hullMMB(f1, AllowPartial=true, ...
                OutputDir=testCase.OutputDir, Verbose=false);
            testCase.verifyTrue(mmb.partial);
            s = fileread(fullfile(testCase.OutputDir, "mmb_part_summary.txt"));
            testCase.verifySubstring(s, "% PARTIAL");
        end

        function summaryCarriesHashesAndTolerances(testCase)
            vfile = testCase.writeTempVertexFile(eye(4, 3), "hashes");
            mmb = hullMMB(vfile, OutputDir=testCase.OutputDir, Verbose=false);
            s = fileread(fullfile(testCase.OutputDir, "mmb_hashes_summary.txt"));
            testCase.verifySubstring(s, "vertices_sha256=" + mmb.verticesSha256);
            testCase.verifySubstring(s, "faces_sha256=" + mmb.facesSha256);
            testCase.verifySubstring(s, "tolerance-dependent");
            testCase.verifyEqual(strlength(mmb.verticesSha256), 64);
        end
    end

    methods (Access = private)
        function vfile = writeTempVertexFile(testCase, verts, name, opts)
            arguments
                testCase
                verts double
                name (1,1) string
                opts.InputDatasetId (1,1) string = ""    % default: own name
                opts.Chunk double = []
                opts.NChunks double = []
                opts.ClaimVertices double = []
            end
            if opts.InputDatasetId == ""
                opts.InputDatasetId = name;
            end
            if isempty(opts.ClaimVertices)
                opts.ClaimVertices = size(verts, 1);
            end
            if isempty(opts.Chunk)
                vfile = fullfile(testCase.OutputDir, "mmb_" + name + ".txt");
            else
                vfile = fullfile(testCase.OutputDir, ...
                    "mmb_" + name + "_chunk" + opts.Chunk + ".txt");
            end
            fid = fopen(vfile, 'w');
            cleanupObj = onCleanup(@() fclose(fid));
            fprintf(fid, "%% MMB vertices from CUDA kernel\n");
            fprintf(fid, "%% Input: /test/generators_%s.txt\n", opts.InputDatasetId);
            fprintf(fid, "%% n=10, tiles_total=210, tiles_intersecting=5, vertices=%d\n", ...
                opts.ClaimVertices);
            if ~isempty(opts.Chunk)
                fprintf(fid, "%% chunk=%d, nchunks=%d\n", opts.Chunk, opts.NChunks);
            end
            fprintf(fid, "%.17g %.17g %.17g\n", verts');
            fprintf(fid, "%% complete vertices=%d\n", size(verts, 1));
        end
    end
end
