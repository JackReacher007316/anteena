function report = verify_web_input(cfg)
%VERIFY_WEB_INPUT  Verify one web-dashboard input independently in MATLAB.
%
%   report = verify_web_input(cfg)
%
%   CFG is the input pushed by the dashboard - what jsondecode returns for
%   the bridge (GET /api/matlab/input) or for data/user_input.json:
%       cfg.antenna               antenna key, e.g. 'patch'
%       cfg.model                 ML surrogate selected, e.g. 'gpr'
%       cfg.params                slider values, e.g. cfg.params.length
%       cfg.dashboard.physics     numbers of the dashboard EM engine
%       cfg.dashboard.prediction  ML values displayed (S11, Gain, BW, Fr)
%
%   MATLAB recomputes the design with ANTENNA_MODEL and returns
%       report.matlab   MATLAB results (S11, Gain, BW, Fr, ...)
%       report.checks   struct array, one row per comparison with fields
%                       group ('Engine' | 'ML surrogate'), metric, unit,
%                       dashboard, matlab, abs_err, tol, pass
%       report.status   'PASS' | 'FAIL' | 'NO DATA' | 'ERROR'
%       report.summary  one-line verdict, e.g. 'PASS - 10/10 checks agree'
%       report.rf       RF figures derived from MATLAB's result (VSWR,
%                       |Gamma|, return/mismatch loss, -10 dB band)
%       report.curve    S11 traces for plotting (.f, .matlab, .prediction)
%       report.prediction  the ML values the dashboard displayed
%       report.warnings cellstr (inputs missing/unknown, ...)
%
%   Checks
%     Engine        every number of the dashboard EM engine must equal the
%                   MATLAB result: |error| <= max(1e-9, 1e-6 * |MATLAB|).
%     ML surrogate  the ML prediction displayed by the dashboard must agree
%                   with MATLAB within S11 1 dB, Gain 0.5 dB,
%                   Fr 1 % (at least 10 MHz) and BW 5 % (at least 20 MHz).
%
%   Example
%       cfg = jsondecode(fileread(fullfile('..', 'data', 'user_input.json')));
%       r = verify_web_input(cfg);
%       disp(r.summary), struct2table(r.checks)
%
%   See also LIVE_VERIFY, ANTENNA_MODEL, ANTENNA_S11_CURVE.

    report = struct();
    report.seq = get_num(cfg, 'seq', NaN);
    report.session = get_str(cfg, 'session', '');
    report.antenna = lower(get_str(cfg, 'antenna', 'patch'));
    report.antenna_name = get_str(cfg, 'antenna_name', '');
    report.model = upper(get_str(cfg, 'model', ''));
    report.params = get_field(cfg, 'params', struct());
    report.matlab = struct();
    report.checks = empty_checks();
    report.n_checks = 0;
    report.n_pass = 0;
    report.status = 'ERROR';
    report.summary = '';
    report.warnings = {};
    report.rf = struct();
    report.curve = struct('f', [], 'matlab', [], 'prediction', []);
    report.freq_range = [];
    report.prediction = struct();
    report.source = '';
    report.computed_ms = NaN;
    report.received_at = '';

    % Custom user-described antenna: MATLAB accepts the design and plots
    % supplied sweep data, but does not pretend a generic geometry has an
    % analytical/full-wave solver. Derived RF values come only from provided
    % measurements or the supplied S11 trace.
    if strcmp(report.antenna, 'custom')
        report = verify_custom_review(report, cfg);
        return;
    end

    try
        [ml, info] = antenna_model(report.antenna, report.params);
    catch err
        report.summary = ['MATLAB engine error: ' err.message];
        return;
    end
    report.matlab = ml;
    report.params = info.params;
    report.freq_range = info.freq_range;
    if isempty(report.antenna_name)
        report.antenna_name = info.name;
    end
    for k = 1:numel(info.missing)
        nm = info.missing{k};
        report.warnings{end + 1} = sprintf('Input "%s" was not received - MATLAB used the default %g.', ...
                                           nm, info.defaults.(nm));
    end
    for k = 1:numel(info.unknown)
        report.warnings{end + 1} = sprintf('Input "%s" is not used by the %s engine.', ...
                                           info.unknown{k}, report.antenna);
    end

    dash = get_field(cfg, 'dashboard', struct());
    phys = get_field(dash, 'physics', struct());
    pred = get_field(dash, 'prediction', struct());
    report.prediction = pred;

    % 1) Engine: dashboard EM engine vs MATLAB re-computation (should be exact).
    checks = empty_checks();
    names = fieldnames(phys);
    for k = 1:numel(names)
        nm = names{k};
        if ~isfield(ml, nm) || ~is_num(phys.(nm)) || ~is_num(ml.(nm))
            continue;
        end
        tol = max(1e-9, 1e-6 * abs(ml.(nm)));
        checks(end + 1) = make_check('Engine', nm, phys.(nm), ml.(nm), tol); %#ok<AGROW>
    end

    % 2) ML surrogate shown in the dashboard vs MATLAB reference.
    %        metric  abs tol  rel tol
    spec = {'S11',   1.0,     0; ...
            'Gain',  0.5,     0; ...
            'Fr',    0.01,    0.01; ...
            'BW',    0.02,    0.05};
    for k = 1:size(spec, 1)
        nm = spec{k, 1};
        if ~isfield(pred, nm) || ~isfield(ml, nm) || ~is_num(pred.(nm)) || ~is_num(ml.(nm))
            continue;
        end
        tol = max(spec{k, 2}, spec{k, 3} * abs(ml.(nm)));
        checks(end + 1) = make_check('ML surrogate', nm, pred.(nm), ml.(nm), tol); %#ok<AGROW>
    end

    report.checks = checks;
    report.n_checks = numel(checks);
    report.n_pass = sum([checks.pass]);
    if report.n_checks == 0
        report.status = 'NO DATA';
        report.summary = 'Computed in MATLAB - no dashboard numbers to compare';
    elseif report.n_pass == report.n_checks
        report.status = 'PASS';
        report.summary = sprintf('PASS - %d/%d checks agree', report.n_pass, report.n_checks);
    else
        report.status = 'FAIL';
        bad = checks(~[checks.pass]);
        labels = cell(1, numel(bad));
        for k = 1:numel(bad)
            labels{k} = sprintf('%s %s', bad(k).group, bad(k).metric);
        end
        report.summary = sprintf('FAIL - %d of %d checks outside tolerance: %s', ...
                                 numel(bad), report.n_checks, strjoin(labels, ', '));
    end

    % S11 traces: MATLAB reference and the dashboard ML prediction.
    [f, s_ml] = antenna_s11_curve(report.antenna, ml, info.freq_range);
    report.curve.f = f;
    report.curve.matlab = s_ml;
    if all(isfield(pred, {'S11', 'Fr', 'BW'})) && is_num(pred.S11) && is_num(pred.Fr) && is_num(pred.BW)
        po = ml;
        po.S11 = pred.S11;
        po.Fr = pred.Fr;
        po.BW = pred.BW;
        [~, s_pr] = antenna_s11_curve(report.antenna, po, info.freq_range);
        report.curve.prediction = s_pr;
    end

    report.rf = rf_figures(ml, f, s_ml);
end

% -------------------------------------------------------------------------
function report = verify_custom_review(report, cfg)
%VERIFY_CUSTOM_REVIEW  Accept user-defined topologies and inspect supplied data.
    review = get_field(cfg, 'review', struct());
    measurements = get_field(review, 'measurements', struct());
    report.matlab = struct('Fr', NaN, 'S11', NaN, 'Gain', NaN, 'BW', NaN);
    report.checks = empty_checks();
    report.n_checks = 0;
    report.n_pass = 0;
    report.freq_range = [];
    report.curve = struct('f', [], 'matlab', [], 'prediction', []);
    report.prediction = struct();
    report.warnings = {'Custom antenna accepted. MATLAB has no universal EM model for arbitrary geometry; values below are from your uploaded data, not a full-wave simulation.'};

    if isstruct(measurements)
        report.matlab.Fr = custom_num(measurements, 'frequency_GHz', NaN);
        report.matlab.S11 = custom_num(measurements, 's11_dB', NaN);
        report.matlab.Gain = custom_num(measurements, 'gain_dBi', NaN);
        report.matlab.BW = custom_num(measurements, 'bandwidth_GHz', NaN);
    end

    f = get_field(review, 'trace_f_GHz', []);
    s = get_field(review, 'trace_s11_dB', []);
    if isnumeric(f) && isnumeric(s) && numel(f) == numel(s) && numel(f) >= 3
        keep = isfinite(f(:)) & isfinite(s(:));
        f = double(f(keep));
        s = double(s(keep));
        [f, order] = sort(f);
        s = s(order);
        if numel(f) >= 3 && all(diff(f) > 0)
            report.curve.f = f(:)';
            report.curve.matlab = s(:)';
            [report.matlab.S11, at] = min(s);
            report.matlab.Fr = f(at);
            report.freq_range = [min(f), max(f)];
            if isnan(report.matlab.BW)
                [lo, hi] = band_edges(f, s, -10);
                if isfinite(lo) && isfinite(hi)
                    report.matlab.BW = hi - lo;
                end
            end
        end
    end

    if isempty(report.curve.f) && isfinite(report.matlab.Fr) && ...
            isfinite(report.matlab.S11) && isfinite(report.matlab.BW) && report.matlab.BW > 0
        % Clearly approximate visualization based on user-provided summary
        % metrics; never represented as an EM prediction.
        f0 = report.matlab.Fr;
        span = max(3 * report.matlab.BW, 0.05 * f0);
        f = linspace(max(eps, f0 - span), f0 + span, 201);
        sigma = max(report.matlab.BW / 2.355, eps);
        s = -1 + (report.matlab.S11 + 1) .* exp(-0.5 .* ((f - f0) ./ sigma).^2);
        report.curve.f = f;
        report.curve.matlab = s;
        report.freq_range = [min(f), max(f)];
    end

    report.status = 'CUSTOM DATA RECEIVED';
    if ~isempty(report.curve.f)
        report.summary = sprintf('Custom review received - plotted %d user-data sweep samples; no arbitrary-geometry solver was run', numel(report.curve.f));
    else
        report.summary = 'Custom design received in MATLAB - add a frequency/S11 sweep for RF plots; no generic EM solver was run';
    end
    report.rf = rf_figures(report.matlab, report.curve.f, report.curve.matlab);
end

function value = custom_num(s, field, fallback)
    value = fallback;
    if isstruct(s) && isfield(s, field) && isnumeric(s.(field)) && isscalar(s.(field)) && isfinite(s.(field))
        value = double(s.(field));
    end
end

% -------------------------------------------------------------------------
function rf = rf_figures(ml, f, s11_trace)
%RF_FIGURES  Standard RF quantities derived from MATLAB's own result.
    rf = struct();
    s11 = ml.S11;
    g = 10^(s11 / 20);                 % |Gamma|
    rf.S11_dB = s11;
    rf.return_loss_dB = -s11;
    rf.gamma = g;
    if g < 1
        rf.VSWR = (1 + g) / (1 - g);
        rf.mismatch_loss_dB = -10 * log10(1 - g^2);
    else
        rf.VSWR = Inf;
        rf.mismatch_loss_dB = Inf;
    end
    rf.reflected_pct = 100 * g^2;
    rf.matched = s11 <= -10;
    [lo, hi] = band_edges(f, s11_trace, -10);
    rf.band_lo_GHz = lo;
    rf.band_hi_GHz = hi;
    rf.band_GHz = hi - lo;
end

function [lo, hi] = band_edges(f, s, level)
%BAND_EDGES  Edges of the contiguous band (s <= level) around the minimum,
%   linearly interpolated between samples. NaN when s never reaches level.
    lo = NaN;
    hi = NaN;
    if isempty(s)
        return;
    end
    [smin, im] = min(s);
    if smin > level
        return;
    end
    a = im;
    while a > 1 && s(a - 1) <= level
        a = a - 1;
    end
    b = im;
    while b < numel(s) && s(b + 1) <= level
        b = b + 1;
    end
    lo = f(a);
    if a > 1
        lo = f(a - 1) + (level - s(a - 1)) * (f(a) - f(a - 1)) / (s(a) - s(a - 1));
    end
    hi = f(b);
    if b < numel(s)
        hi = f(b) + (level - s(b)) * (f(b + 1) - f(b)) / (s(b + 1) - s(b));
    end
end

function c = make_check(group, metric, dash_val, matlab_val, tol)
    err = abs(double(dash_val) - double(matlab_val));
    c = struct('group', group, 'metric', metric, 'unit', unit_of(metric), ...
               'dashboard', double(dash_val), 'matlab', double(matlab_val), ...
               'abs_err', err, 'tol', tol, 'pass', err <= tol);
end

function c = empty_checks()
    c = struct('group', {}, 'metric', {}, 'unit', {}, 'dashboard', {}, ...
               'matlab', {}, 'abs_err', {}, 'tol', {}, 'pass', {});
end

function u = unit_of(metric)
    switch metric
        case {'S11', 'Isolation', 'DG', 'sll', 'fbRatio', 'frontToBack', 'crossPol'}
            u = 'dB';
        case {'Gain', 'Directivity'}
            u = 'dBi';
        case {'BW', 'Fr', 'f1', 'f2', 'f3', 'notchFreq'}
            u = 'GHz';
        case {'efficiency', 'sizeReduction'}
            u = '%';
        case {'hpbw', 'beamwidth', 'beamwidthE', 'beamwidthH'}
            u = 'deg';
        case {'Rin', 'Xin', 'Rrad'}
            u = 'Ohm';
        case 'groupDelay'
            u = 'ns';
        otherwise
            u = '';
    end
end

function v = get_field(s, name, default)
    if isstruct(s) && isscalar(s) && isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    else
        v = default;
    end
end

function v = get_str(s, name, default)
    v = get_field(s, name, default);
    if isstring(v)
        v = char(v);
    end
    if ~ischar(v)
        v = default;
    end
end

function v = get_num(s, name, default)
    v = get_field(s, name, default);
    if ~(isnumeric(v) && isscalar(v))
        v = default;
    end
    v = double(v);
end

function tf = is_num(v)
    tf = isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v);
end
