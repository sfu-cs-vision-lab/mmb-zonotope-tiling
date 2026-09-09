% runs_validate_10nm.m  The documented small example.
%
%   One dataset: D65 to A, CIE 1931 2-degree observer, 10 nm bands, target
%   from 50% flat reflectance. It finishes in seconds of GPU time.
%
%   Expected result (see README.md): 1976 boundary vertices, 3948 faces,
%   hull volume 1.619729587421700e+02 in the white_y100 frame.
%
%   Usage:
%       bash mmb_run.sh runs/runs_validate_10nm.m
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

prepareGenerators("1931_2deg", "D65", "A", ...
    Spacing=10, Refl=0.5, DataDir="data");
