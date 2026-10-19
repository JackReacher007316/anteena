function live_verify(varargin)
%LIVE_VERIFY  Live link: web dashboard -> MATLAB verification window.
%
%   Every input you change in the web dashboard (antenna type, ML model and
%   slider values) shows up in MATLAB immediately. MATLAB re-computes the
%   antenna independently (ANTENNA_MODEL), verifies the numbers the
%   dashboard displays, and sends its verdict back to the dashboard.
%
%   1) Start the bridge from the repository root and open the dashboard:
%          python dashboard/bridge_server.py      ->  http://localhost:8000
%   2) In MATLAB (inside the matlab folder):
%          live_verify
%
%   Usage
%       live_verify                           connect to http://127.0.0.1:8000
%                                             (already running: show the window)
%       live_verify('http://127.0.0.1:8080')  other bridge address
%       live_verify('Period', 0.5)            poll period in seconds (0.25)
%       live_verify('Quiet', true)            no Command Window log
%       live_verify stop                      stop the link, close the window
%
%   Closing the window only hides it: the link keeps running in the
%   background, so the dashboard stays connected. Bring the window back with
%   live_verify or with CONNECT MATLAB in the dashboard; end the link with
%   live_verify stop (or by quitting MATLAB). install_live_link.bat adds
%   live_verify to MATLAB's startup.m, so every MATLAB session is linked.
%
%   While the link runs
%     * the window "Web Dashboard -> MATLAB Live Verification" shows the
%       received inputs, MATLAB's S11 trace against the dashboard ML
%       prediction, RF figures and the check table
%       (dashboard value | MATLAB value | error | tolerance | PASS/FAIL)
%     * base-workspace variables are refreshed on every dashboard change:
%           web_input          the raw input received from the dashboard
%           web_verification   MATLAB's verification report
%     * if the bridge is not reachable, data/user_input.json is watched
%       instead (file mode)
%
%   See also VERIFY_WEB_INPUT, ANTENNA_MODEL, TEST_ANTENNA_MODEL.

    TAG = 'AnteenaLiveVerify';

    if nargin == 1 && is_text(varargin{1}) && strcmpi(varargin{1}, 'stop')
        if stop_link(TAG) > 0
            fprintf('[live_verify] Live link stopped.\n');
        else
            fprintf('[live_verify] No live link was running.\n');
        end
        return;
    end

    % Already running (e.g. started by startup.m, then "matlab -r live_verify"):
    % a plain live_verify just brings the window back.
    if nargin == 0 && show_running_link(TAG)
        fprintf('[live_verify] Live link already running - window shown.\n');
        return;
    end

    opt = parse_options(varargin{:});
    stop_link(TAG);                       % only one live link at a time

    here = fileparts(mfilename('fullpath'));
    st = struct( ...
        'url', opt.Url, ...
        'file', fullfile(fileparts(here), 'data', 'user_input.json'), ...
        'fileText', '', ...
        'lastSeq', NaN, ...
        'lastSession', '', ...
        'source', 'none', ...             % 'bridge' | 'file' | 'none'
        'bridgeFails', 0, ...
        'nextBridgeTry', 0, ...
        'lastError', '', ...
        'count', 0, ...
        'lastInputAt', -Inf, ...
        'pendingLog', false, ...
        'paused', false, ...
        'report', [], ...
        'lastCfg', [], ...
        'showSeq', NaN, ...               % dashboard "show the window" requests
        'showSession', '', ...
        'version', version_tag());
    clock0 = tic;
    getopts = weboptions('Timeout', opt.Timeout, 'ContentType', 'text', ...
                         'CharacterEncoding', 'UTF-8');
    postopts = weboptions('Timeout', opt.Timeout, 'ContentType', 'text', ...
                          'CharacterEncoding', 'UTF-8', 'MediaType', 'application/json');

    ui = build_ui(TAG, opt.Url);          % [] when no display -> console mode
    if ~isempty(ui)
        ui.fig.CloseRequestFcn = @on_close;
        ui.pause.ValueChangedFcn = @on_pause;
    end

    link_timer = timer('Name', TAG, 'Tag', TAG, 'ExecutionMode', 'fixedSpacing', ...
                       'Period', opt.Period, 'BusyMode', 'drop', ...
                       'TimerFcn', @on_tick, 'ErrorFcn', @on_timer_error, ...
                       'StopFcn', @(obj, ~) delete(obj));
    link_timer.UserData = struct('show', @show_window);   % used by show_running_link

    if ~opt.Quiet
        rule = repmat('=', 1, 74);
        fprintf('%s\n', rule);
        fprintf(' LIVE LINK  web dashboard -> MATLAB                       (live_verify)\n');
        fprintf('   bridge : %s   (start it: python dashboard/bridge_server.py)\n', opt.Url);
        fprintf('   vars   : web_input, web_verification  (refreshed on every change)\n');
        fprintf('   window : closing it keeps the link running; live_verify shows it again\n');
        fprintf('   stop   : live_verify stop\n');
        fprintf('%s\n', rule);
    end
    start(link_timer);

    % ---------------------------------------------------------------------
    % Nested callbacks (share st, ui, opt with the function above).
    % ---------------------------------------------------------------------
    function on_tick(~, ~)
        if ~isempty(ui) && ~isvalid(ui.fig)
            ui = [];                      % window deleted: keep linking in the background
        end
        try
            [cfg, src] = fetch_input();
            if ~isempty(cfg) && ~st.paused
                handle_input(cfg, src);
            end
            refresh_banner();
            if st.pendingLog && toc(clock0) - st.lastInputAt > 0.8
                st.pendingLog = false;    % log once the sliders settle
                if ~opt.Quiet
                    print_report(st.report);
                end
            end
        catch tick_err
            st.lastError = tick_err.message;
            refresh_banner();
        end
    end

    function [cfg, src] = fetch_input()
    %FETCH_INPUT  Newest dashboard input: bridge first, JSON file as fallback.
        cfg = [];
        if toc(clock0) >= st.nextBridgeTry
            try
                since = st.lastSeq;
                if isnan(since)
                    since = -1;
                end
                session = st.lastSession;
                if isempty(session)
                    session = 'none';
                end
                txt = webread([st.url '/api/matlab/input'], ...
                              'since', sprintf('%d', since), 'session', session, ...
                              'client', 'matlab', 'ver', st.version, getopts);
                reply = jsondecode(char(txt));
                check_show_request(reply);
                st.bridgeFails = 0;
                st.source = 'bridge';
                src = 'bridge';
                if strncmp(st.lastError, 'bridge:', 7)
                    st.lastError = '';
                end
                if isstruct(reply) && isfield(reply, 'params') && is_new(reply)
                    cfg = reply;
                end
                return;
            catch web_err
                st.bridgeFails = st.bridgeFails + 1;
                st.nextBridgeTry = toc(clock0) + min(5, 0.5 * st.bridgeFails);
                st.lastError = ['bridge: ' web_err.message];
            end
        end

        % Fallback: watch data/user_input.json (written by the bridge).
        src = 'none';
        if ~isfile(st.file)
            st.source = src;
            return;
        end
        src = 'file';
        st.source = src;
        try
            raw = fileread(st.file);
        catch
            return;                       % being replaced - next tick
        end
        if strcmp(raw, st.fileText)
            return;
        end
        try
            reply = jsondecode(raw);
        catch
            return;                       % half-written - next tick
        end
        st.fileText = raw;
        if isstruct(reply) && isfield(reply, 'params') && is_new(reply)
            cfg = reply;
        end
    end

    function check_show_request(reply)
    %CHECK_SHOW_REQUEST  CONNECT MATLAB in the dashboard asks to show the window.
        if ~isstruct(reply) || ~isfield(reply, 'show_seq')
            return;
        end
        n = double(reply.show_seq);
        session = '';
        if isfield(reply, 'session')
            session = char(reply.session);
        end
        if isnan(st.showSeq) || ~strcmp(session, st.showSession)
            st.showSeq = n;               % first contact / new bridge: just remember
            st.showSession = session;
        elseif n > st.showSeq
            st.showSeq = n;
            show_window();
        end
    end

    function show_window()
    %SHOW_WINDOW  Re-open the live window (after it was closed) or raise it.
        if ~isempty(ui) && isvalid(ui.fig)
            try
                figure(ui.fig);           % bring to front
            catch
                % cosmetic only
            end
            return;
        end
        ui = build_ui(TAG, opt.Url);
        if isempty(ui)
            return;                       % no display: Command Window mode
        end
        ui.fig.CloseRequestFcn = @on_close;
        ui.pause.ValueChangedFcn = @on_pause;
        if st.paused
            ui.pause.Value = true;
            ui.pause.Text = 'Resume';
        end
        if ~isempty(st.report)
            render_report(ui, st.report, st.lastCfg);
        end
        refresh_banner();
    end

    function tf = is_new(reply)
        session = '';
        if isfield(reply, 'session')
            session = char(reply.session);
        end
        tf = ~isfield(reply, 'seq') || ~isequal(reply.seq, st.lastSeq) || ...
             ~strcmp(session, st.lastSession);
    end

    function handle_input(cfg, src)
        t_start = tic;
        report = verify_web_input(cfg);
        report.source = src;
        report.computed_ms = 1000 * toc(t_start);
        report.received_at = char(datetime('now', 'Format', 'HH:mm:ss'));

        st.lastSeq = report.seq;
        st.lastSession = report.session;
        st.count = st.count + 1;
        st.report = report;
        st.lastCfg = cfg;
        st.lastInputAt = toc(clock0);
        st.pendingLog = true;

        assignin('base', 'web_input', cfg);
        assignin('base', 'web_verification', report);
        if ~isempty(ui)
            render_report(ui, report, cfg);
        end
        if strcmp(src, 'bridge')
            post_result(report);
        end
    end

    function post_result(report)
    %POST_RESULT  Send MATLAB's verdict back so the dashboard can show it.
        payload = struct( ...
            'seq', report.seq, ...
            'session', report.session, ...
            'antenna', report.antenna, ...
            'model', report.model, ...
            'status', report.status, ...
            'summary', report.summary, ...
            'n_checks', report.n_checks, ...
            'n_pass', report.n_pass, ...
            'checks', {num2cell(report.checks)}, ...
            'matlab', report.matlab, ...
            'rf', report.rf, ...
            'warnings', {report.warnings}, ...
            'computed_ms', report.computed_ms, ...
            'matlab_version', st.version);
        try
            webwrite([st.url '/api/matlab/result'], jsonencode(payload), postopts);
        catch post_err
            st.lastError = ['bridge: result not delivered (' post_err.message ')'];
        end
    end

    function refresh_banner()
        if isempty(ui) || ~isvalid(ui.fig)
            return;
        end
        [txt, color] = banner_text(st);
        if ~strcmp(ui.banner.Text, txt)
            ui.banner.Text = txt;
            ui.banner.FontColor = color;
        end
    end

    function on_pause(btn, ~)
        st.paused = logical(btn.Value);
        if st.paused
            btn.Text = 'Resume';
        else
            btn.Text = 'Pause';
        end
        refresh_banner();
    end

    function on_close(~, ~)
    %ON_CLOSE  Closing the window hides it; the link keeps running.
        if ~isempty(ui) && isvalid(ui.fig)
            delete(ui.fig);
        end
        ui = [];
        if ~opt.Quiet
            fprintf(['[live_verify] Window closed - the live link keeps running in the background.\n' ...
                     '              Show it again: live_verify   (or CONNECT MATLAB in the dashboard)\n' ...
                     '              Stop the link: live_verify stop\n']);
        end
    end

    function on_timer_error(~, evt)
        msg = 'unknown error';
        if isfield(evt, 'Data') && isfield(evt.Data, 'message')
            msg = evt.Data.message;
        end
        fprintf(2, '[live_verify] Timer error: %s\n', msg);
    end
end

% =========================================================================
% Local functions
% =========================================================================
function opt = parse_options(varargin)
    opt = struct('Url', 'http://127.0.0.1:8000', 'Period', 0.25, ...
                 'Timeout', 2, 'Quiet', false);
    args = varargin;
    if ~isempty(args) && is_text(args{1}) && startsWith(lower(char(args{1})), 'http')
        opt.Url = char(args{1});
        args(1) = [];
    end
    if mod(numel(args), 2) ~= 0
        error('live_verify:badArguments', ...
              'Options are name/value pairs, e.g. live_verify(''Period'', 0.5).');
    end
    for k = 1:2:numel(args)
        name = char(args{k});
        value = args{k + 1};
        switch lower(name)
            case 'url'
                opt.Url = char(value);
            case 'period'
                opt.Period = max(0.05, double(value));
            case 'timeout'
                opt.Timeout = double(value);
            case 'quiet'
                opt.Quiet = logical(value);
            otherwise
                error('live_verify:badOption', ...
                      'Unknown option ''%s''. Valid options: Url, Period, Timeout, Quiet.', name);
        end
    end
    while endsWith(opt.Url, '/')
        opt.Url = opt.Url(1:end - 1);
    end
end

function tf = show_running_link(tag)
%SHOW_RUNNING_LINK  Ask a running live link to show its window.
    tf = false;
    tmrs = timerfindall('Tag', tag);
    for k = 1:numel(tmrs)
        t = tmrs(k);
        if ~isvalid(t) || ~strcmp(t.Running, 'on')
            continue;
        end
        ud = t.UserData;
        if isstruct(ud) && isfield(ud, 'show')
            ud.show();
            tf = true;
            return;
        end
    end
end

function n = stop_link(tag)
%STOP_LINK  Stop/delete the live-link timer and close its window.
    n = 0;
    tmrs = timerfindall('Tag', tag);
    for k = 1:numel(tmrs)
        n = n + 1;
        try
            stop(tmrs(k));
        catch
        end
        try
            if isvalid(tmrs(k))
                delete(tmrs(k));
            end
        catch
        end
    end
    figs = findall(groot, 'Type', 'figure', 'Tag', tag);
    n = n + numel(figs);
    delete(figs);
end

function v = version_tag()
    try
        v = version();
    catch
        v = 'MATLAB';
    end
end

function tf = is_text(x)
    tf = ischar(x) || (isstring(x) && isscalar(x));
end

function C = palette()
    C.bg = [0.07 0.08 0.11];
    C.panel = [0.11 0.12 0.16];
    C.panel2 = [0.15 0.16 0.21];
    C.text = [0.90 0.92 0.95];
    C.muted = [0.60 0.64 0.70];
    C.grid = [0.30 0.32 0.40];
    C.green = [0.00 0.85 0.55];
    C.cyan = [0.25 0.72 1.00];
    C.amber = [1.00 0.72 0.20];
    C.red = [1.00 0.38 0.38];
    C.failbg = [0.32 0.10 0.12];
end

function name = mono_font()
    if ispc
        name = 'Consolas';
    elseif ismac
        name = 'Menlo';
    else
        name = 'DejaVu Sans Mono';
    end
end

function ui = build_ui(tag, url)
%BUILD_UI  Create the live window; returns [] when graphics are unavailable.
    ui = [];
    C = palette();
    try
        fig = uifigure('Name', 'Web Dashboard -> MATLAB Live Verification', ...
                       'Tag', tag, 'Color', C.bg, 'Position', [60 60 1320 790], ...
                       'Visible', 'off');
    catch ui_err
        fprintf(2, '[live_verify] No graphics (%s) - Command Window mode.\n', ui_err.message);
        return;
    end
    try
        movegui(fig, 'center');
    catch
        % cosmetic only
    end

    root = uigridlayout(fig, [3 2]);
    root.RowHeight = {40, '1.15x', '1x'};
    root.ColumnWidth = {440, '1x'};
    root.Padding = [10 10 10 10];
    root.RowSpacing = 8;
    root.ColumnSpacing = 10;
    root.BackgroundColor = C.bg;

    % Row 1: status banner + pause button.
    top = uigridlayout(root, [1 2]);
    top.Layout.Row = 1;
    top.Layout.Column = [1 2];
    top.ColumnWidth = {'1x', 110};
    top.Padding = [0 0 0 0];
    top.BackgroundColor = C.bg;
    ui.banner = uilabel(top, 'Text', ['  Waiting for the dashboard bridge at ' url ' ...'], ...
                        'FontSize', 15, 'FontWeight', 'bold', 'FontColor', C.amber, ...
                        'BackgroundColor', C.panel);
    ui.pause = uibutton(top, 'state', 'Text', 'Pause', 'FontWeight', 'bold', ...
                        'BackgroundColor', C.panel2, 'FontColor', C.text);

    % Row 2, left: inputs received from the dashboard.
    p_in = uipanel(root, 'Title', 'INPUTS RECEIVED FROM THE WEB DASHBOARD', ...
                   'FontWeight', 'bold', 'ForegroundColor', C.cyan, ...
                   'BackgroundColor', C.panel);
    p_in.Layout.Row = 2;
    p_in.Layout.Column = 1;
    g_in = uigridlayout(p_in, [2 1]);
    g_in.RowHeight = {46, '1x'};
    g_in.Padding = [8 8 8 8];
    g_in.BackgroundColor = C.panel;
    ui.antenna = uilabel(g_in, 'Text', 'Waiting for the first input ... move a slider in the dashboard.', ...
                         'FontSize', 14, 'FontWeight', 'bold', 'FontColor', C.text, 'WordWrap', 'on');
    ui.inputs = uitable(g_in, 'ColumnName', {'Input', 'Value', 'Range', 'MATLAB field'}, ...
                        'RowName', {}, 'Data', cell(0, 4), 'FontSize', 13, ...
                        'ColumnWidth', {'auto', 70, 90, 'auto'}, ...
                        'BackgroundColor', [C.panel2; C.panel], 'ForegroundColor', C.text);

    % Row 2, right: S11 - MATLAB reference vs dashboard ML prediction.
    ax = uiaxes(root);
    ax.Layout.Row = 2;
    ax.Layout.Column = 2;
    ax.Color = C.panel;
    ax.XColor = C.text;
    ax.YColor = C.text;
    ax.GridColor = C.grid;
    ax.GridAlpha = 0.6;
    ax.XGrid = 'on';
    ax.YGrid = 'on';
    ax.Box = 'on';
    ax.FontSize = 11;
    hold(ax, 'on');
    yline(ax, -10, '--', '-10 dB', 'Color', C.red, 'LineWidth', 1.3, ...
          'LabelHorizontalAlignment', 'left', 'HandleVisibility', 'off');
    ui.ref_line = plot(ax, NaN, NaN, '-', 'Color', C.green, 'LineWidth', 2.6, ...
                       'DisplayName', 'MATLAB (independent)');
    ui.pred_line = plot(ax, NaN, NaN, '--', 'Color', C.cyan, 'LineWidth', 2.0, ...
                        'DisplayName', 'Dashboard ML prediction');
    ui.ref_mark = plot(ax, NaN, NaN, 'p', 'MarkerSize', 15, 'MarkerFaceColor', C.green, ...
                       'MarkerEdgeColor', [1 1 1], 'HandleVisibility', 'off');
    ui.pred_mark = plot(ax, NaN, NaN, 'o', 'MarkerSize', 8, 'MarkerFaceColor', C.cyan, ...
                        'MarkerEdgeColor', [1 1 1], 'HandleVisibility', 'off');
    xlabel(ax, 'Frequency (GHz)');
    ylabel(ax, 'S_{11} (dB)');
    title(ax, 'S11 - waiting for input', 'Interpreter', 'none', 'Color', C.text);
    ylim(ax, [-45 0]);
    legend(ax, [ui.ref_line ui.pred_line], 'Location', 'southeast', ...
           'TextColor', C.text, 'Color', C.panel2, 'EdgeColor', C.grid);
    ui.ax = ax;

    % Row 3, left: RF analysis of MATLAB's own result.
    p_rf = uipanel(root, 'Title', 'MATLAB RF ANALYSIS', 'FontWeight', 'bold', ...
                   'ForegroundColor', C.cyan, 'BackgroundColor', C.panel);
    p_rf.Layout.Row = 3;
    p_rf.Layout.Column = 1;
    g_rf = uigridlayout(p_rf, [1 1]);
    g_rf.Padding = [10 6 10 6];
    g_rf.BackgroundColor = C.panel;
    ui.rf = uilabel(g_rf, 'Text', '', 'FontName', mono_font(), 'FontSize', 13, ...
                    'FontColor', C.text, 'VerticalAlignment', 'top', 'WordWrap', 'on');

    % Row 3, right: verification table.
    p_ck = uipanel(root, 'Title', 'VERIFICATION: DASHBOARD vs MATLAB', 'FontWeight', 'bold', ...
                   'ForegroundColor', C.cyan, 'BackgroundColor', C.panel);
    p_ck.Layout.Row = 3;
    p_ck.Layout.Column = 2;
    g_ck = uigridlayout(p_ck, [1 1]);
    g_ck.Padding = [8 8 8 8];
    g_ck.BackgroundColor = C.panel;
    ui.checks = uitable(g_ck, 'ColumnName', {'Check', 'Dashboard', 'MATLAB', ...
                        ['|' char(916) '|'], 'Tolerance', 'Result'}, ...
                        'RowName', {}, 'Data', cell(0, 6), 'FontSize', 13, ...
                        'ColumnWidth', {'auto', 'auto', 'auto', 90, 90, 70}, ...
                        'BackgroundColor', [C.panel2; C.panel], 'ForegroundColor', C.text);

    ui.fig = fig;
    fig.Visible = 'on';
end

function render_report(ui, report, cfg)
%RENDER_REPORT  Push one verification report into the live window.
    C = palette();

    ui.antenna.Text = sprintf('%s   |   ML model: %s', report.antenna_name, report.model);
    ui.inputs.Data = input_rows(report, cfg);

    % Verification table.
    n = numel(report.checks);
    rows = cell(n, 6);
    for k = 1:n
        c = report.checks(k);
        label = sprintf('%s: %s', c.group, c.metric);
        if ~isempty(c.unit)
            label = sprintf('%s [%s]', label, c.unit);
        end
        verdict = 'FAIL';
        if c.pass
            verdict = 'PASS';
        end
        rows(k, :) = {label, sprintf('%.6g', c.dashboard), sprintf('%.6g', c.matlab), ...
                      sprintf('%.2g', c.abs_err), sprintf('%.2g', c.tol), verdict};
    end
    ui.checks.Data = rows;
    removeStyle(ui.checks);
    if n > 0
        passed = find([report.checks.pass]);
        failed = find(~[report.checks.pass]);
        if ~isempty(passed)
            addStyle(ui.checks, uistyle('FontColor', C.green, 'FontWeight', 'bold'), ...
                     'cell', [passed(:), 6 * ones(numel(passed), 1)]);
        end
        if ~isempty(failed)
            addStyle(ui.checks, uistyle('FontColor', C.red, 'FontWeight', 'bold', ...
                                        'BackgroundColor', C.failbg), 'row', failed);
        end
    end

    % S11 traces and resonance markers.
    ml = report.matlab;
    if isempty(report.curve.f)
        set(ui.ref_line, 'XData', NaN, 'YData', NaN);
        set(ui.pred_line, 'XData', NaN, 'YData', NaN);
        set(ui.ref_mark, 'XData', NaN, 'YData', NaN);
        set(ui.pred_mark, 'XData', NaN, 'YData', NaN);
        title(ui.ax, report.summary, 'Interpreter', 'none', 'Color', C.red);
    else
        set(ui.ref_line, 'XData', report.curve.f, 'YData', report.curve.matlab, ...
            'DisplayName', sprintf('MATLAB (independent): f_0 = %.4g GHz, S_{11} = %.2f dB', ml.Fr, ml.S11));
        set(ui.ref_mark, 'XData', ml.Fr, 'YData', ml.S11);
        pred = report.prediction;
        if ~isempty(report.curve.prediction)
            set(ui.pred_line, 'XData', report.curve.f, 'YData', report.curve.prediction, ...
                'DisplayName', sprintf('Dashboard %s: f_0 = %.4g GHz, S_{11} = %.2f dB', ...
                                       report.model, pred.Fr, pred.S11));
            set(ui.pred_mark, 'XData', pred.Fr, 'YData', pred.S11);
        else
            set(ui.pred_line, 'XData', NaN, 'YData', NaN, 'DisplayName', 'Dashboard ML prediction');
            set(ui.pred_mark, 'XData', NaN, 'YData', NaN);
        end
        xlim(ui.ax, report.freq_range);
        title(ui.ax, sprintf('%s  -  input #%g', report.antenna_name, report.seq), ...
              'Interpreter', 'none', 'Color', C.text);
    end

    ui.rf.Text = rf_lines(report);
end

function rows = input_rows(report, cfg)
    names = fieldnames(report.params);
    meta = param_meta(cfg);
    rows = cell(numel(names), 4);
    for k = 1:numel(names)
        nm = names{k};
        label = nm;
        span = '';
        for j = 1:numel(meta)
            if strcmp(meta{j}.id, nm)
                label = meta{j}.label;
                span = sprintf('%g - %g', meta{j}.min, meta{j}.max);
                break;
            end
        end
        rows(k, :) = {label, sprintf('%.6g', report.params.(nm)), span, nm};
    end
end

function meta = param_meta(cfg)
%PARAM_META  Slider metadata sent by the dashboard as a cell of structs.
    meta = {};
    if isstruct(cfg) && isfield(cfg, 'param_meta') && ~isempty(cfg.param_meta)
        m = cfg.param_meta;
        if isstruct(m)
            meta = num2cell(m(:)');
        elseif iscell(m)
            meta = m(:)';
        end
    end
    keep = false(1, numel(meta));
    for k = 1:numel(meta)
        keep(k) = isstruct(meta{k}) && all(isfield(meta{k}, {'id', 'label', 'min', 'max'}));
    end
    meta = meta(keep);
end

function out = rf_lines(report)
    out = {};
    if ~strcmp(report.status, 'ERROR')
        ml = report.matlab;
        rf = report.rf;
        out{end + 1} = sprintf('Resonance f0       %.4f GHz', ml.Fr);
        out{end + 1} = sprintf('S11 | Return loss  %.2f dB | %.2f dB', rf.S11_dB, rf.return_loss_dB);
        out{end + 1} = sprintf('|Gamma| | VSWR     %.4f | %.3f', rf.gamma, rf.VSWR);
        out{end + 1} = sprintf('Mismatch loss      %.3f dB (%.2f %% reflected)', ...
                                 rf.mismatch_loss_dB, rf.reflected_pct);
        if rf.matched && ~isnan(rf.band_lo_GHz)
            out{end + 1} = sprintf('-10 dB band        %.4f - %.4f GHz (%.4f GHz)', ...
                                     rf.band_lo_GHz, rf.band_hi_GHz, rf.band_GHz);
        else
            out{end + 1} = '-10 dB band        none (S11 above -10 dB)';
        end
        out{end + 1} = sprintf('Gain | BW          %.2f dBi | %.4g GHz', ml.Gain, ml.BW);
    end
    out{end + 1} = sprintf('Verdict            %s', report.summary);
    out{end + 1} = sprintf('Computed in        %.2f ms (%s)', report.computed_ms, report.source);
    for k = 1:numel(report.warnings)
        out{end + 1} = ['NOTE  ' report.warnings{k}]; %#ok<AGROW>
    end
end

function [txt, color] = banner_text(st)
    C = palette();
    bullet = char(9679);
    r = st.report;
    switch st.source
        case 'bridge'
            if isempty(r)
                txt = sprintf('  %s LIVE - connected to %s. Move a slider in the dashboard ...', bullet, st.url);
                color = C.green;
            else
                txt = sprintf('  %s LIVE   #%g   %s / %s   |   %s   |   %s', bullet, r.seq, ...
                              upper(r.antenna), r.model, r.summary, r.received_at);
                color = verdict_color(r.status, C);
            end
        case 'file'
            txt = sprintf('  %s FILE MODE - bridge offline, watching data/user_input.json', bullet);
            if ~isempty(r)
                txt = sprintf('%s   |   #%g %s   |   %s', txt, r.seq, upper(r.antenna), r.summary);
            end
            color = C.amber;
        otherwise
            txt = sprintf('  %s Waiting for the bridge at %s  (install_live_link.bat starts it)', ...
                          char(9675), st.url);
            color = C.amber;
    end
    if st.paused
        txt = ['  [PAUSED]' txt];
        color = C.amber;
    end
end

function color = verdict_color(status, C)
    switch status
        case 'PASS'
            color = C.green;
        case {'FAIL', 'ERROR'}
            color = C.red;
        otherwise
            color = C.amber;
    end
end

function print_report(r)
%PRINT_REPORT  Compact Command Window log of one verified input.
    if isempty(r)
        return;
    end
    fprintf('%s\n', repmat('-', 1, 74));
    fprintf(' WEB -> MATLAB  #%g  %s   %s (%s)   model %s   [%s]\n', r.seq, r.received_at, ...
            upper(r.antenna), r.antenna_name, r.model, r.source);
    names = fieldnames(r.params);
    for k = 1:numel(names)
        fprintf('   %-16s = %g\n', names{k}, r.params.(names{k}));
    end
    if ~strcmp(r.status, 'ERROR')
        fprintf(' MATLAB : Fr = %.4f GHz   S11 = %.2f dB   Gain = %.2f dBi   BW = %.4g GHz\n', ...
                r.matlab.Fr, r.matlab.S11, r.matlab.Gain, r.matlab.BW);
    end
    fprintf(' VERIFY : %s\n', r.summary);
    for k = 1:numel(r.warnings)
        fprintf(' NOTE   : %s\n', r.warnings{k});
    end
end
