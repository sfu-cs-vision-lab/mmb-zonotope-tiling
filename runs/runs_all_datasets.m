% runs_all_datasets.m  Generate inputs for every dataset in dataset_ids.txt.
%
% The collection driver calls this script through mmb_run.sh, which uses a
% private preparation directory.
%
% Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

here = fileparts(mfilename('fullpath'));
repoRoot = fileparts(here);
datasetIdsFile = fullfile(here, 'dataset_ids.txt');
assert(isfile(datasetIdsFile), 'runs_all_datasets:noDatasetIdsFile', ...
    'collection definition not found: %s', datasetIdsFile);

datasetIds = readlines(datasetIdsFile);
datasetIds = strtrim(datasetIds(strtrim(datasetIds) ~= ""));
fprintf('Generating generators files for %d datasets...\n', numel(datasetIds));

obsPat = "(1931_2deg|1964_10deg|cfb_2deg|cfb_10deg|lms_2deg|lms_10deg)";
for i = 1:numel(datasetIds)
    tok = regexp(datasetIds(i), "^" + obsPat + "_(.+?)_(.+?)_([0-9]+)nm_refl([0-9]+)$", ...
        "tokens", "once");
    assert(~isempty(tok), 'runs_all_datasets:parse', 'cannot parse datasetId: %s', datasetIds(i));
    prepareGenerators(tok(1), tok(2), tok(3), ...
        Spacing=str2double(tok(4)), Refl=str2double(tok(5))/100, ...
        DataDir=fullfile(repoRoot, 'data'));
end
fprintf('Done: %d generator files.\n', numel(datasetIds));
