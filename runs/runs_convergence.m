% runs_convergence.m  Resolution series for convergence analysis
%
% Generate inputs for comparing MMB volumes at four wavelength spacings
% using two observers and three illuminant pairs.
%
%   Configurations:
%       1931_2deg:  D65 -> A, D65 -> D50, D65 -> FL11 at 10, 5, 2, 1nm
%       cfb_2deg:   D65 -> A, D65 -> D50, D65 -> FL11 at 10, 5, 2, 1nm
%       Refl: 50% gray
%       24 generator files total (2 observers x 3 pairs x 4 spacings)
%
%   Approximate compute time per dataset on an H100:
%       10nm: under 1s, 5nm: under 1s, 2nm: about 4min, 1nm: about 4hr.
%       Band counts depend on the observer's wavelength range.
%
%   Usage:
%       bash mmb_run.sh runs/runs_convergence.m
%       bash mmb_run.sh --dry-run runs/runs_convergence.m
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

% 1931 2-deg: three illuminant pairs
prepareGenerators("1931_2deg", "D65", ["A", "D50", "FL11"], ...
    Spacing=[10, 5, 2, 1], Refl=0.5, DataDir="data");

% CFB 2-deg: same three pairs at the same wavelength spacings
prepareGenerators("cfb_2deg", "D65", ["A", "D50", "FL11"], ...
    Spacing=[10, 5, 2, 1], Refl=0.5, DataDir="data");
