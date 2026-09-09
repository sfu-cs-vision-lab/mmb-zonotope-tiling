% runs_1nm_d65_a.m  Single 1nm D65->A MMB
%
%   Usage:
%       bash mmb_run.sh runs/runs_1nm_d65_a.m
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

prepareGenerators("1931_2deg", "D65", "A", Spacing=1, Refl=0.5, DataDir="data");
