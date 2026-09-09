function [rho, check] = findReflectanceWitness(A, b)
% FINDREFLECTANCEWITNESS  Find rho in [0,1] with A*rho close to b.
%   Acceptance requires a finite rho with residual no greater than
%   1e-8*max(1,norm(b,Inf)). The residual is computed directly from rho.
%   Without a witness, the result is indeterminate.
%
%   Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

persistent solverOptions solverSettings
if isempty(solverOptions)
    base = optimoptions("linprog", Display="none", Algorithm="dual-simplex");
    tight = optimoptions(base, ConstraintTolerance=1e-10, OptimalityTolerance=1e-10);
    interior = optimoptions(tight, Algorithm="interior-point");
    newOptions = {base, tight, interior, tight};
    scales = [1, 1, 1, 10];
    newSettings = repmat(struct("algorithm", "", "constraintTolerance", NaN, ...
        "optimalityTolerance", NaN, "equationScale", NaN), 1, numel(newOptions));
    for k = 1:numel(newOptions)
        o = newOptions{k};
        newSettings(k).algorithm = string(o.Algorithm);
        newSettings(k).constraintTolerance = o.ConstraintTolerance;
        newSettings(k).optimalityTolerance = o.OptimalityTolerance;
        newSettings(k).equationScale = scales(k);
    end
    solverSettings = newSettings;
    solverOptions = newOptions;
end

n = size(A, 2);
rho = [];
check = struct("accepted", false, "residual", Inf, "tau", NaN, ...
    "attempts", 0, "exitflags", [], "auxiliaryResiduals", [], ...
    "directResiduals", [], "solverSettings", solverSettings);
if size(b, 2) ~= 1 || size(A, 1) ~= numel(b) || ...
        any(~isfinite(A(:))) || any(~isfinite(b))
    return
end
check.tau = 1e-8 * max(1, norm(b, Inf));
m = size(A, 1);
f = [zeros(n, 1); 1];
lb = zeros(n+1, 1);
ub = [ones(n, 1); Inf];

for k = 1:numel(solverOptions)
    % Rescale the final solve. Check its residual in the original units.
    scale = solverSettings(k).equationScale;
    Ap = [scale*A, -ones(m, 1); -scale*A, -ones(m, 1)];
    [x, ~, exitflag] = linprog(f, Ap, scale*[b; -b], [], [], lb, ub, solverOptions{k});
    check.attempts = k;
    check.exitflags(k) = exitflag;
    check.auxiliaryResiduals(k) = NaN;
    check.directResiduals(k) = Inf;
    if numel(x) ~= n+1 || any(~isfinite(x))
        continue
    end
    check.auxiliaryResiduals(k) = x(end) / scale;
    % Clip to the reflectance bounds before computing the residual.
    candidate = min(1, max(0, x(1:n)));
    residual = norm(A * candidate - b, Inf);
    check.directResiduals(k) = residual;
    if isfinite(residual) && residual < check.residual
        check.residual = residual;
        rho = candidate;
    end
    if isfinite(residual) && residual <= check.tau
        check.accepted = true;
        return
    end
    % Retry when the directly computed residual exceeds the tolerance.
end
end
