function plan = buildfile
% BUILDFILE  Build plan for mmb-zonotope-tiling.
%
%   Run:
%       buildtool check    static code analysis
%       buildtool test     unit tests (runs check first)
%       buildtool          check and test
%
%   Requires the Optimization Toolbox for the reflectance feasibility check.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

import matlab.buildtool.tasks.CodeIssuesTask
import matlab.buildtool.tasks.TestTask

plan = buildplan(localfunctions);

plan("check") = CodeIssuesTask( ...
    SourceFiles=["src", "runs", "tests", "examples"], ...
    WarningThreshold=0);

plan("test") = TestTask( ...
    SourceFiles=["src", "tests"], ...
    TestResults="reports/test-results.xml");
plan("test").Dependencies = "check";

plan.DefaultTasks = ["check", "test"];
end
