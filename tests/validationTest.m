classdef validationTest < matlab.unittest.TestCase
% VALIDATIONTEST  Tests for validateDataset, validateCollection and
% readValidationReport.
%
%   Covers certificate contents, certificate reuse and staleness, the
%   generation-identity check, collection completeness, the complementarity
%   check and reading both certificate field layouts.
%
%   Run:
%       results = runtests("validationTest");
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (Access = private)
        FixDir string
        DatasetId string
        Root string       % mini runs_output
        DatasetIdsFile string
    end

    methods (TestMethodSetup)
        function buildMiniCollection(testCase)
            here = fileparts(mfilename("fullpath"));
            testCase.FixDir = fullfile(here, "fixtures");
            testCase.DatasetId = "1931_2deg_D65_A_10nm_refl50";
            testCase.assumeTrue(isfile(fullfile(testCase.FixDir, ...
                "generators_" + testCase.DatasetId + ".txt")));
            tmp = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            testCase.Root = fullfile(tmp, "runs_output");
            rd = fullfile(testCase.Root, testCase.DatasetId);
            mkdir(fullfile(rd, "results"));
            copyfile(fullfile(testCase.FixDir, "generators_" + testCase.DatasetId + ".txt"), rd);
            for f = ["_vertices.csv", "_faces.csv", "_summary.txt"]
                copyfile(fullfile(testCase.FixDir, "mmb_" + testCase.DatasetId + f), ...
                    fullfile(rd, "results"));
            end
            testCase.DatasetIdsFile = fullfile(tmp, "dataset_ids.txt");
        end
    end

    methods (Test)
        function datasetCertificateWrittenAndPasses(testCase)
            rd = fullfile(testCase.Root, testCase.DatasetId);
            rep = validateDataset(rd, Sample=24, Verbose=false);
            testCase.verifyEqual(string(rep.result), "PASS");
            gj = fullfile(rd, "results", "mmb_" + testCase.DatasetId + "_gate.json");
            testCase.verifyTrue(isfile(gj));
            j = readValidationReport(gj);
            testCase.verifyEqual(string(j.schema), "mmb-dataset-report/2");
            testCase.verifyEqual(string(j.dataset_id), testCase.DatasetId);
            testCase.verifyGreaterThan(strlength(string(j.provenance.meta.source_id)), 0);
            testCase.verifyEqual(string(j.provenance.meta.norm_policy), "white_y100");
            testCase.verifyEqual(strlength(string(j.provenance.meta.generators_payload_sha256)), 64);
            testCase.verifyEqual(j.lp.infeasible, 0);
        end

        function payloadHashIgnoresHeaderTimestamp(testCase)
            % Regenerating generators file stamps a new '% Generated:' line. The
            % payload hash must be invariant to header-only changes.
            rd = fullfile(testCase.Root, testCase.DatasetId);
            rep1 = validateDataset(rd, Sample=8, Verbose=false);
            cd = fullfile(rd, "generators_" + testCase.DatasetId + ".txt");
            txt = string(fileread(cd));
            txt = replace(txt, "% Generated: ", "% Generated: RETIMESTAMPED ");
            fid = fopen(cd, "w"); fprintf(fid, "%s", txt); fclose(fid);
            rep2 = validateDataset(rd, Sample=8, Force=true, Verbose=false);
            testCase.verifyEqual( ...
                string(rep1.provenance.meta.generators_payload_sha256), ...
                string(rep2.provenance.meta.generators_payload_sha256));
        end

        function collectionFailsOnMissingDataset(testCase)
            writelines([testCase.DatasetId; "lms_2deg_D65_A_1nm_refl50"], testCase.DatasetIdsFile);
            cert = validateCollection(testCase.Root, testCase.DatasetIdsFile, Sample=8, Verbose=false);
            testCase.verifyEqual(string(cert.result), "FAIL");
            testCase.verifyEqual(cert.datasets_pass, 1);
            testCase.verifyTrue(any(contains(string(cert.failing_datasets), "lms_2deg")));
        end

        function collectionPassesAndWritesRecords(testCase)
            writelines(testCase.DatasetId, testCase.DatasetIdsFile);
            cert = validateCollection(testCase.Root, testCase.DatasetIdsFile, Sample=8, Verbose=false);
            testCase.verifyEqual(string(cert.result), "PASS");
            outDir = fullfile(fileparts(testCase.Root), "gate_reports");
            testCase.verifyTrue(isfile(fullfile(outDir, "collection_certificate.json")));
            m = string(fileread(fullfile(outDir, "manifest_gated.txt")));
            testCase.verifySubstring(m, "=== " + testCase.DatasetId + " ===");
            testCase.verifySubstring(m, "vertices_sha256:");
            % The certificate reads back with the names docs/VALIDATION_FORMAT.md documents.
            r = readValidationReport(fullfile(outDir, "collection_certificate.json"));
            testCase.verifyEqual(string(r.schema), "mmb-collection-certificate/1");
            testCase.verifyEqual(r.datasets_expected, 1);
            testCase.verifyEqual(r.datasets_pass, 1);
            testCase.verifyEqual(r.datasets_fail, 0);
            testCase.verifyEmpty(r.failing_datasets);
            testCase.verifyEqual(strlength(string(r.dataset_ids_file_sha256)), 64);
        end

        function complementaryVolumesMustAgree(testCase)
            ids = ["pair_refl10"; "pair_refl90"];
            writelines(ids, testCase.DatasetIdsFile);
            testCase.writePassingCertificate(ids(1), 2);
            testCase.writePassingCertificate(ids(2), 2);
            cert = validateCollection(testCase.Root, testCase.DatasetIdsFile, Verbose=false);
            testCase.verifyEqual(cert.complementarity.pairs_checked, 1);
            testCase.verifyTrue(cert.complementarity.all_pass);
            testCase.verifyEqual(cert.pairs(1).rel_asym, 0);

            testCase.writePassingCertificate(ids(2), 2.002);
            cert = validateCollection(testCase.Root, testCase.DatasetIdsFile, Verbose=false);
            testCase.verifyFalse(cert.complementarity.all_pass);
            testCase.verifyEqual(cert.pairs(1).rel_asym, 0.002 / 2.002, "RelTol", 1e-12);
            testCase.verifyEqual(string(cert.result), "FAIL");
        end

        function passCertificateSkippedOnResume(testCase)
            rd = fullfile(testCase.Root, testCase.DatasetId);
            validateDataset(rd, Sample=8, Verbose=false);
            gj = fullfile(rd, "results", "mmb_" + testCase.DatasetId + "_gate.json");
            d1 = dir(gj);
            rep2 = validateDataset(rd, Sample=8, Verbose=false);   % must skip, not check again
            d2 = dir(gj);
            testCase.verifyEqual(d1.datenum, d2.datenum);
            testCase.verifyEqual(string(rep2.result), "PASS");
        end

        function staleCertificateIsNotHonored(testCase)
            % A PASS certificate must never outlive its data. Validate to
            % PASS, change the vertices, then validate again without Force:
            % the reuse path must notice and validate again.
            rd = fullfile(testCase.Root, testCase.DatasetId);
            rep1 = validateDataset(rd, Sample=8, Verbose=false);
            testCase.assumeEqual(string(rep1.result), "PASS");
            vcsv = fullfile(rd, "results", "mmb_" + testCase.DatasetId + "_vertices.csv");
            V = readmatrix(vcsv, FileType="text");
            V(5, :) = V(5, :) * 1.03;
            fid = fopen(vcsv, "w"); fprintf(fid, "%.17g,%.17g,%.17g\n", V'); fclose(fid);
            rep2 = validateDataset(rd, Sample=8, Verbose=false);   % unforced
            testCase.verifyEqual(string(rep2.result), "FAIL", ...
                "a stale PASS certificate was honored over changed result files");
        end

        function generationMismatchFails(testCase)
            % Results computed from a different generation of the input must
            % fail. The payload hash the kernel echoed into the summary no
            % longer matches the current generators file.
            rd = fullfile(testCase.Root, testCase.DatasetId);
            cd0 = fullfile(rd, "generators_" + testCase.DatasetId + ".txt");
            txt = fileread(cd0);
            txt2 = strrep(txt, "4.752112", "4.752113");   % in-place payload nudge
            testCase.assumeFalse(strcmp(txt, txt2));
            fid = fopen(cd0, "w"); fprintf(fid, "%s", txt2); fclose(fid);
            rep = validateDataset(rd, Sample=8, Force=true, Verbose=false);
            testCase.verifyEqual(string(rep.result), "FAIL");
            testCase.verifyTrue(any(contains(rep.reasons, "GENERATION MISMATCH")));
        end

    end

    methods (Access = private)
        function writePassingCertificate(testCase, datasetId, volume)
            % A PASS certificate whose hashes match its files, which
            % validateDataset reuses without checking the files again.
            rd = fullfile(testCase.Root, datasetId);
            results = fullfile(rd, "results");
            if ~isfolder(results), mkdir(results); end
            files = struct("generators", fullfile(rd, "generators_" + datasetId + ".txt"), ...
                "vertices", fullfile(results, "mmb_" + datasetId + "_vertices.csv"), ...
                "faces", fullfile(results, "mmb_" + datasetId + "_faces.csv"), ...
                "summary", fullfile(results, "mmb_" + datasetId + "_summary.txt"));
            sha = struct();
            for f = string(fieldnames(files))'
                writelines(datasetId + " " + f, files.(f));
                sha.(f) = testCase.sha256OfFile(files.(f));
            end
            report = struct("schema", "mmb-dataset-report/2", "dataset_id", datasetId, ...
                "result", "PASS", "sha256", sha, ...
                "volume", struct("recomputed", volume), ...
                "integrity", struct("csvRows", 0, "csvFaces", 0), ...
                "provenance", struct("meta", struct("generators_payload_sha256", "")), ...
                "lp", struct("feasible", 0, "sampled", 0));
            writelines(string(jsonencode(report)), ...
                fullfile(results, "mmb_" + datasetId + "_gate.json"));
        end

        function hex = sha256OfFile(~, path)
            fid = fopen(path, "r");
            bytes = fread(fid, Inf, "*uint8");
            fclose(fid);
            md = java.security.MessageDigest.getInstance("SHA-256");
            md.update(bytes);
            hex = lower(string(reshape(dec2hex(typecast(md.digest(), "uint8"))', 1, [])));
        end
    end
end
