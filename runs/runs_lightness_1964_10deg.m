% runs_lightness_1964_10deg.m  Lightness series for CIE 1964 10-deg observer
%
%   Purpose: Measure how MMB volume scales with lightness level
%   (flat reflectance) for three illuminant pairs.
%
%   Configurations:
%       D65 -> A, D65 -> D50, D65 -> FL11 at 1nm, 1964_10deg
%       Reflectance: 0.1, 0.2, 0.3, 0.5, 0.7, 0.9
%       18 generator files total (3 pairs x 6 reflectance levels)
%
%   Expected compute (H100):
%       1nm (n=401): ~4hr each -> parallel array
%       Total: ~72 GPU-hours across 18 runs
%
%   Usage:
%       bash mmb_run.sh runs/runs_lightness_1964_10deg.m
%       bash mmb_run.sh --dry-run runs/runs_lightness_1964_10deg.m
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

illum2s = ["A", "A", "A", "A", "A", "A", ...
    "D50", "D50", "D50", "D50", "D50", "D50", ...
    "FL11", "FL11", "FL11", "FL11", "FL11", "FL11"];
refls = [0.1, 0.2, 0.3, 0.5, 0.7, 0.9, ...
    0.1, 0.2, 0.3, 0.5, 0.7, 0.9, ...
    0.1, 0.2, 0.3, 0.5, 0.7, 0.9];

prepareGenerators("1964_10deg", "D65", illum2s, ...
    Spacing=1, Refl=refls, DataDir="data");
