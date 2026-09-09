function exitCode = run_validation(resultsMatPath, summaryTxtPath)
%RUN_VALIDATION  Driver for the validateAllMMBTest suite.
%
%   exitCode = RUN_VALIDATION(resultsMatPath, summaryTxtPath)
%
%   Runs the validateAllMMBTest test class against every dataset in
%   runs_output/, saves results to resultsMatPath and writes a
%   human-readable summary to summaryTxtPath. Returns 0 on success,
%   1 if any test fails or is incomplete.
%
%   If SLURM_CPUS_PER_TASK >= 2 is set, attempts parallel execution.
%   Uses serial execution if parpool is unavailable.

arguments
    resultsMatPath (1,:) char
    summaryTxtPath (1,:) char
end

addpath('tests');

fprintf('=== MMB Validation Suite ===\n');
fprintf('  Datasets will be discovered from: %s\n', fullfile(pwd, 'runs_output'));

suite = matlab.unittest.TestSuite.fromClass(?validateAllMMBTest);
fprintf('  Total tests in suite: %d\n\n', numel(suite));

ncpu = str2double(getenv('SLURM_CPUS_PER_TASK'));
if isnan(ncpu) || ncpu < 2
    ncpu = 1;
end

runner = matlab.unittest.TestRunner.withTextOutput( ...
    'OutputDetail', matlab.unittest.Verbosity.Concise);

if ncpu >= 2
    fprintf('  Attempting parallel execution with %d workers...\n', ncpu);
    try
        pool = gcp('nocreate');
        if isempty(pool)
            parpool('local', ncpu);
        end
        results = runInParallel(runner, suite);
        fprintf('  Parallel execution completed.\n');
    catch ME
        fprintf('  Parallel execution failed (%s): %s\n', ...
            ME.identifier, ME.message);
        fprintf('  Falling back to serial execution.\n');
        results = run(runner, suite);
    end
else
    fprintf('  Running serially.\n');
    results = run(runner, suite);
end

fprintf('\n=== Summary ===\n');
nTotal = numel(results);
nPassed = sum([results.Passed]);
nFailed = sum([results.Failed]);
nIncomplete = sum([results.Incomplete]);
fprintf('  Total tests:    %d\n', nTotal);
fprintf('  Passed:         %d  (%.1f%%)\n', nPassed, 100*nPassed/max(nTotal,1));
fprintf('  Failed:         %d\n', nFailed);
fprintf('  Incomplete:     %d\n', nIncomplete);

save(resultsMatPath, 'results');
fprintf('  Results saved:  %s\n', resultsMatPath);

fid = fopen(summaryTxtPath, 'w');
fprintf(fid, '=== MMB Validation Summary ===\n');
fprintf(fid, 'Generated: %s\n\n', string(datetime("now", Format="yyyy-MM-dd HH:mm:ss")));
fprintf(fid, 'Total tests:  %d\n', nTotal);
fprintf(fid, 'Passed:       %d  (%.1f%%)\n', nPassed, 100*nPassed/max(nTotal,1));
fprintf(fid, 'Failed:       %d\n', nFailed);
fprintf(fid, 'Incomplete:   %d\n', nIncomplete);
fprintf(fid, '\n');

if nFailed > 0
    fprintf(fid, '=== Failed tests ===\n');
    failed = results([results.Failed]);
    for k = 1:numel(failed)
        fprintf(fid, '  %s\n', failed(k).Name);
    end
    fprintf(fid, '\n');
end

if nIncomplete > 0
    fprintf(fid, '=== Incomplete tests ===\n');
    incomplete = results([results.Incomplete]);
    for k = 1:numel(incomplete)
        fprintf(fid, '  %s\n', incomplete(k).Name);
    end
end

fclose(fid);
fprintf('  Summary saved:  %s\n', summaryTxtPath);

if nFailed > 0 || nIncomplete > 0
    fprintf('\n*** %d test(s) did not pass. See summary file. ***\n', ...
        nFailed + nIncomplete);
    exitCode = 1;
else
    fprintf('\nAll tests passed.\n');
    exitCode = 0;
end
end
