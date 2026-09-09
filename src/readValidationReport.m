function report = readValidationReport(path)
% READVALIDATIONREPORT  Read a validation certificate.
%
%   report = readValidationReport(path) reads a dataset or collection
%   certificate and returns it as a struct.
%
%   A dataset certificate names its dataset in dataset_id and the source
%   that ran its checks in provenance.meta.source_id. A collection
%   certificate reports datasets_expected, datasets_pass, datasets_fail
%   and failing_datasets. docs/VALIDATION_FORMAT.md describes every field.
%
%   report.schema is the schema identifier exactly as the file declares it.
%
%   INPUTS:
%       path   path to a dataset certificate, mmb_<dataset_id>_gate.json,
%              or a collection certificate
%
%   OUTPUTS:
%       report   decoded certificate
%
%   EXAMPLE:
%       r = readValidationReport("results/mmb_1931_2deg_D65_A_10nm_refl50_gate.json");
%       fprintf("%s %s\n", r.dataset_id, r.result);
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

arguments
    path (1,1) string {mustBeFile}
end

report = jsondecode(fileread(path));

end
