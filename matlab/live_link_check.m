function ok = live_link_check(out_file, bridge_url)
%LIVE_LINK_CHECK  One-shot health check of the MATLAB side of the live link.
%
%   live_link_check                        check against http://127.0.0.1:8000
%   ok = live_link_check(out_file, url)    also write the result as JSON
%
%   Prints what works and what does not:
%     1. MATLAB version and userpath (the folder that holds startup.m)
%     2. engine self-test: MATLAB reproduces all 30 dashboard engines
%        (TEST_ANTENNA_MODEL)
%     3. MATLAB can reach the bridge (python dashboard/bridge_server.py)
%     4. the dashboard's current input verifies in MATLAB (VERIFY_WEB_INPUT)
%
%   install_live_link.bat runs it once, in batch mode:
%       matlab -wait -batch "live_link_check('<file>', '<url>')"
%   and shows the result.
%
%   See also LIVE_VERIFY, TEST_ANTENNA_MODEL, VERIFY_WEB_INPUT.

    if nargin < 2 || isempty(bridge_url)
        bridge_url = 'http://127.0.0.1:8000';
    end
    bridge_url = char(bridge_url);
    while endsWith(bridge_url, '/')
        bridge_url = bridge_url(1:end - 1);
    end

    r = struct();
    r.ok = false;
    r.matlab_version = version();
    r.userpath = char(userpath);
    r.matlab_dir = fileparts(mfilename('fullpath'));
    r.bridge_url = bridge_url;
    r.engine_ok = false;
    r.engine_message = '';
    r.bridge_ok = false;
    r.bridge_message = '';
    r.verify_status = '';
    r.verify_summary = '';

    % 2. Engine self-test.
    try
        r.engine_ok = logical(test_antenna_model());
        if r.engine_ok
            r.engine_message = 'MATLAB reproduces all 30 dashboard engines';
        else
            r.engine_message = 'MATLAB and dashboard engines differ (see the log above)';
        end
    catch err
        r.engine_message = ['engine self-test failed: ' err.message];
    end

    % 3. The bridge (status only - this check must not count as a live link).
    opts = weboptions('Timeout', 5, 'ContentType', 'text', 'CharacterEncoding', 'UTF-8');
    try
        status = jsondecode(char(webread([bridge_url '/api/status'], opts)));
        r.bridge_ok = isstruct(status) && isfield(status, 'session');
        if r.bridge_ok
            r.bridge_message = ['MATLAB reached the bridge at ' bridge_url];
        else
            r.bridge_message = [bridge_url ' answered, but it is not the live-link bridge (old version?)'];
        end
    catch err
        r.bridge_message = ['MATLAB could not reach the bridge at ' bridge_url ': ' err.message];
    end

    % 4. The dashboard's current input, verified in MATLAB.
    if r.bridge_ok
        try
            cfg = jsondecode(char(webread([bridge_url '/api/matlab/input'], opts)));
            if isstruct(cfg) && isfield(cfg, 'params')
                rep = verify_web_input(cfg);
                r.verify_status = rep.status;
                r.verify_summary = rep.summary;
            else
                r.verify_summary = 'no dashboard input yet (open the website and move a slider)';
            end
        catch err
            r.verify_status = 'ERROR';
            r.verify_summary = err.message;
        end
    end
    r.ok = r.engine_ok && r.bridge_ok && ~strcmp(r.verify_status, 'ERROR');

    rule = repmat('=', 1, 74);
    fprintf('%s\n LIVE LINK CHECK (MATLAB side)\n%s\n', rule, rule);
    fprintf(' MATLAB        : %s\n', r.matlab_version);
    fprintf(' userpath      : %s\n', r.userpath);
    fprintf(' engines       : %s  %s\n', pass_text(r.engine_ok), r.engine_message);
    fprintf(' bridge        : %s  %s\n', pass_text(r.bridge_ok), r.bridge_message);
    if ~isempty(r.verify_summary)
        fprintf(' current input : %s %s\n', r.verify_status, r.verify_summary);
    end
    fprintf(' RESULT        : %s\n%s\n', pass_text(r.ok), rule);

    if nargin >= 1 && ~isempty(out_file)
        [fid, msg] = fopen(char(out_file), 'w', 'n', 'UTF-8');
        if fid < 0
            warning('anteena:liveLinkCheck', 'Could not write %s: %s', char(out_file), msg);
        else
            fprintf(fid, '%s', jsonencode(r));
            fclose(fid);
        end
    end
    ok = r.ok;
end

function s = pass_text(tf)
    if tf
        s = 'OK  ';
    else
        s = 'FAIL';
    end
end
