classdef compareReferenceTest < matlab.unittest.TestCase
% COMPAREREFERENCETEST  Tests for input and volume comparisons.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

    properties (Access = private)
        Root string
        RefCsv string
    end

    methods (TestMethodSetup)
        function setup(testCase)
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            testCase.Root = fullfile(folder, "results");
            testCase.RefCsv = fullfile(folder, "reference.csv");
        end
    end

    methods (Access = private)
        function writeCertificate(testCase, datasetId, volume, result)
            if nargin < 4, result = "PASS"; end
            folder = fullfile(testCase.Root, datasetId, "results");
            if ~isfolder(folder), mkdir(folder); end
            report = struct("dataset_id", datasetId, "result", result, ...
                "volume", struct("recomputed", volume));
            writelines(string(jsonencode(report)), ...
                fullfile(folder, "mmb_" + datasetId + "_gate.json"));
        end
        function writeReference(testCase, rows)
            writelines(["dataset_id,ref_volume"; rows(:)], testCase.RefCsv);
        end
        function result = compare(testCase)
            result = compareReference("volumes", testCase.Root, ...
                testCase.RefCsv, Verbose=false);
        end
        function [datasetId, ids, stored] = writeStoredInput(testCase)
            datasetId = "1931_2deg_D65_A_10nm_refl50";
            output = fullfile(testCase.Root, datasetId);
            mkdir(output);
            prepareGenerators("1931_2deg", "D65", "A", OutputDir=output);
            stored = fullfile(output, "generators_" + datasetId + ".txt");
            ids = fullfile(testCase.Root, "dataset_ids.txt");
            writelines(datasetId, ids);
        end
        function changeDigit(~, file, digit)
            % Change one mantissa digit of the first generator value in the
            % payload. Digit 1 is the leading digit and 16 the last printed one.
            lines = readlines(file);
            k = find(startsWith(lines, "% payload_sha256="), 1) + 3;
            fields = split(lines(k));
            m = char(fields(2));
            pos = digit + (digit > 1);
            m(pos) = char('0' + mod(m(pos) - '0' + 1, 10));
            fields(2) = string(m);
            lines(k) = join(fields, " ");
            writelines(lines, file);
        end
    end

    methods (Test)
        function matchingVolumesPass(testCase)
            testCase.writeReference(["a,100"; "b,200"]);
            testCase.writeCertificate("a", 100);
            testCase.writeCertificate("b", 200);
            r = testCase.compare();
            testCase.verifyTrue(r.pass);
            testCase.verifyEqual(r.matched, 2);
        end
        function largeDifferencesFailInBothDirections(testCase)
            testCase.writeReference(["a,100"; "b,100"]);
            testCase.writeCertificate("a", 100.001);
            testCase.writeCertificate("b", 99.999);
            r = testCase.compare();
            testCase.verifyFalse(r.pass);
            testCase.verifyEqual(numel(r.failures), 2);
        end
        function smallDifferencesPassInBothDirections(testCase)
            testCase.writeReference(["a,100"; "b,100"]);
            testCase.writeCertificate("a", 100*(1+5e-10));
            testCase.writeCertificate("b", 100*(1-5e-10));
            r = testCase.compare();
            testCase.verifyTrue(r.pass);
        end
        function missingDatasetFails(testCase)
            testCase.writeReference(["a,100"; "b,200"]);
            testCase.writeCertificate("a", 100);
            r = testCase.compare();
            testCase.verifyFalse(r.pass);
            testCase.verifyEqual(r.missing, "b");
        end
        function failedCertificateDoesNotPass(testCase)
            testCase.writeReference("a,100");
            testCase.writeCertificate("a", 100, "FAIL");
            r = testCase.compare();
            testCase.verifyFalse(r.pass);
        end
        function invalidReferenceIsRejected(testCase)
            for rows = {strings(0,1), ["a,100"; "a,100"], "a,0", "a,NaN"}
                testCase.writeReference(rows{1});
                testCase.verifyError(@() testCase.compare(), "compareReference:badReference");
            end
        end
        function invalidRecordedVolumeFails(testCase)
            testCase.writeReference("a,100");
            testCase.writeCertificate("a", -1);
            r = testCase.compare();
            testCase.verifyFalse(r.pass);
        end
        function regeneratedInputMatchesItsReference(testCase)
            [~, ids] = testCase.writeStoredInput();
            r = compareReference("inputs", testCase.Root, ids, Verbose=false);
            testCase.verifyTrue(r.pass);
            testCase.verifyEqual(r.bitIdentical, 1);
        end
        function inputChangeInLeadingDigitIsDivergent(testCase)
            [datasetId, ids, stored] = testCase.writeStoredInput();
            testCase.changeDigit(stored, 1);
            r = compareReference("inputs", testCase.Root, ids, Verbose=false);
            testCase.verifyFalse(r.pass);
            testCase.verifyEqual(r.mismatched, datasetId);
            testCase.verifyEqual(r.divergent, datasetId);
            testCase.verifyEmpty(r.lsbOnly);
        end
        function inputChangeInLastPlaceIsLsbOnly(testCase)
            [datasetId, ids, stored] = testCase.writeStoredInput();
            testCase.changeDigit(stored, 16);
            r = compareReference("inputs", testCase.Root, ids, Verbose=false);
            testCase.verifyFalse(r.pass);
            testCase.verifyEqual(r.mismatched, datasetId);
            testCase.verifyEqual(r.lsbOnly, datasetId);
            testCase.verifyEmpty(r.divergent);
        end
        function missingInputFails(testCase)
            mkdir(testCase.Root);
            ids = fullfile(testCase.Root, "dataset_ids.txt");
            writelines("1931_2deg_D65_A_10nm_refl50", ids);
            r = compareReference("inputs", testCase.Root, ids, Verbose=false);
            testCase.verifyFalse(r.pass);
            testCase.verifyEqual(numel(r.missingStored), 1);
        end
    end
end
