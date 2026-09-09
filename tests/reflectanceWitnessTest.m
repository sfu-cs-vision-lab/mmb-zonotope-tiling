classdef reflectanceWitnessTest < matlab.unittest.TestCase
% REFLECTANCEWITNESSTEST  Tests for findReflectanceWitness.
%
%   Covers witness acceptance, the solver retries and the rule that a
%   small solver residual cannot override the direct check.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.
    methods (Test)
        function storedVerticesHaveValidWitnesses(testCase)
            here = fileparts(mfilename("fullpath"));
            fixture = jsondecode(fileread(fullfile(here, ...
                "fixtures", "witness_rows_cfb_FL11_refl10.json")));
            for k = 1:numel(fixture.rows)
                b = fixture.targets(k, :)';
                [rho, check] = findReflectanceWitness(fixture.A, b);
                testCase.assertTrue(check.accepted, ...
                    sprintf("Stored vertex row %d", fixture.rows(k)));
                testCase.verifyTrue(all(isfinite(rho) & rho >= 0 & rho <= 1));
                residual = norm(fixture.A * rho - b, Inf);
                testCase.verifyEqual(check.residual, residual);
                testCase.verifyEqual(check.tau, 1e-8 * max(1, norm(b, Inf)));
                testCase.verifyLessThanOrEqual(residual, check.tau);
            end
        end

        function unrealizableTargetFailsAfterAllRetries(testCase)
            [rho, check] = findReflectanceWitness(eye(6), 2*ones(6, 1));
            testCase.verifyFalse(check.accepted);
            testCase.verifyEqual(check.attempts, 4);
            testCase.verifyEqual(numel(check.exitflags), 4);
            testCase.verifyGreaterThan(check.residual, check.tau);
            testCase.verifyTrue(all(rho >= 0 & rho <= 1));
        end

        function smallSolverResidualCannotOverrideDirectCheck(testCase)
            % The first solve may tolerate this discrepancy, but it exceeds
            % the scientific acceptance tolerance and must fail all retries.
            [~, check] = findReflectanceWitness(eye(6), (1+5e-8)*ones(6, 1));
            testCase.verifyFalse(check.accepted);
            testCase.verifyEqual(check.attempts, 4);
            testCase.verifyGreaterThan(check.residual, check.tau);
        end

        function nonfiniteTargetDoesNotPass(testCase)
            b = zeros(6, 1); b(2) = NaN;
            [rho, check] = findReflectanceWitness(eye(6), b);
            testCase.verifyFalse(check.accepted);
            testCase.verifyEmpty(rho);
            testCase.verifyEqual(check.attempts, 0);
        end
    end
end
