% runs_observer_comparison.m  MMB across all observer functions
%
%   Purpose: Compare exact MMBs across all six supported observer
%   functions for three illuminant pairs spanning smooth daylight
%   (D50), standard incandescent (A) and narrowband fluorescent (FL11).
%
%   Configurations:
%       D65 -> A, D65 -> D50, D65 -> FL11 at 1nm, 50% gray
%       Observers: 1931_2deg, 1964_10deg, cfb_2deg, cfb_10deg,
%                  lms_2deg, lms_10deg
%       18 generator files total (3 pairs x 6 observers)
%
%   Expected compute (H100):
%       1nm (n=391 or 401): ~4hr each -> parallel array
%       Total: ~72 GPU-hours across 18 runs
%
%   Usage:
%       bash mmb_run.sh runs/runs_observer_comparison.m
%       bash mmb_run.sh --dry-run runs/runs_observer_comparison.m
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

observers = ["1931_2deg", "1964_10deg", "cfb_2deg", "cfb_10deg", ...
    "lms_2deg", "lms_10deg"];
illum2s = ["A", "D50", "FL11"];

for i = 1:numel(observers)
    prepareGenerators(observers(i), "D65", illum2s, ...
        Spacing=1, Refl=0.5, DataDir="data");
end
