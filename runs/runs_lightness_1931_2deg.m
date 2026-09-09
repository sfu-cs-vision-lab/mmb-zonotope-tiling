% runs_lightness_1931_2deg.m  Lightness series for CIE 1931 2-deg observer
%
%   Purpose: Measure how MMB volume scales with lightness level
%   (flat reflectance) for three illuminant pairs.
%
%   Configurations:
%       D65 -> A, D65 -> D50, D65 -> FL11 at 1nm, 1931_2deg
%       Reflectance: 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9
%       27 generator files total (3 pairs x 9 reflectance levels)
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.
illum2s = ["A", "A", "A", "A", "A", "A", "A", "A", "A", ...
    "D50", "D50", "D50", "D50", "D50", "D50", "D50", "D50", "D50", ...
    "FL11", "FL11", "FL11", "FL11", "FL11", "FL11", "FL11", "FL11", "FL11"];
refls = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, ...
    0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, ...
    0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9];
prepareGenerators("1931_2deg", "D65", illum2s, ...
    Spacing=1, Refl=refls, DataDir="data");
