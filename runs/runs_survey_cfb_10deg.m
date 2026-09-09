% runs_survey_cfb_10deg.m  Illuminant survey for CIE cone-fundamental 10-deg observer
%
%   Purpose: Exact 1nm MMBs for D65 paired with all 38 standard
%   illuminants using the CIE cone-fundamental-based 10-degree observer.
%
%   Configurations:
%       D65 -> each of 38 standard illuminants at 1nm
%       Observer: cfb_10deg, Refl: 50% gray
%       38 generator files total
%
%   Expected compute (H100):
%       1nm (n=391): ~4hr each -> parallel array
%       Total: ~152 GPU-hours across 38 runs
%
%   Usage:
%       bash mmb_run.sh runs/runs_survey_cfb_10deg.m
%       bash mmb_run.sh --dry-run runs/runs_survey_cfb_10deg.m
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

illum2List = ["A", "D50", ...
    "FL1", "FL2", "FL3", "FL4", "FL5", "FL6", ...
    "FL7", "FL8", "FL9", "FL10", "FL11", "FL12", ...
    "FL3.1", "FL3.2", "FL3.3", "FL3.4", "FL3.5", ...
    "FL3.6", "FL3.7", "FL3.8", "FL3.9", "FL3.10", ...
    "FL3.11", "FL3.12", "FL3.13", "FL3.14", "FL3.15", ...
    "LED-B1", "LED-B2", "LED-B3", "LED-B4", "LED-B5", ...
    "LED-BH1", "LED-RGB1", "LED-V1", "LED-V2"];

prepareGenerators("cfb_10deg", "D65", illum2List, ...
    Spacing=1, Refl=0.5, DataDir="data");
