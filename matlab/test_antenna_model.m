function ok = test_antenna_model(fixture_file)
%TEST_ANTENNA_MODEL  Prove that MATLAB's engine reproduces the web dashboard.
%
%   test_antenna_model
%   ok = test_antenna_model(fixture_file)
%
%   Compares ANTENNA_MODEL and ANTENNA_S11_CURVE against reference values
%   computed by the dashboard's own JavaScript engines
%   (tests/fixtures/engine_reference.json, generated with
%   "node tests/gen_engine_reference.js"). For all 30 antenna types it
%   checks every output for the default design, the slider extremes and
%   random slider positions, plus the catalog (names, chart ranges,
%   defaults) and the S11 trace. Returns true when everything matches.
%
%   See also ANTENNA_MODEL, ANTENNA_S11_CURVE, LIVE_VERIFY.

    if nargin < 1 || isempty(fixture_file)
        here = fileparts(mfilename('fullpath'));
        fixture_file = fullfile(fileparts(here), 'tests', 'fixtures', 'engine_reference.json');
    end
    ref = jsondecode(fileread(fixture_file));
    antennas = as_cell(ref.antennas);

    fprintf('MATLAB engine vs dashboard JavaScript engine (%d antenna types)\n', numel(antennas));
    total_fail = 0;
    total_values = 0;
    worst = 0;
    for a = 1:numel(antennas)
        A = antennas{a};
        problems = {};
        cases = as_cell(A.cases);
        info = [];
        for k = 1:numel(cases)
            [out, info] = antenna_model(A.key, cases{k}.params);
            expected = cases{k}.outputs;
            names = fieldnames(expected);
            for n = 1:numel(names)
                nm = names{n};
                total_values = total_values + 1;
                if ~isfield(out, nm)
                    problems{end + 1} = sprintf('case %d: output %s missing', k, nm); %#ok<AGROW>
                    continue;
                end
                err = abs(out.(nm) - expected.(nm));
                worst = max(worst, err / max(1, abs(expected.(nm))));
                if ~(err <= max(1e-9, 1e-9 * abs(expected.(nm))))
                    problems{end + 1} = sprintf('case %d: %s MATLAB %.12g vs dashboard %.12g', ...
                                                k, nm, out.(nm), expected.(nm)); %#ok<AGROW>
                end
            end
        end

        % Catalog: name, S11 chart range and default inputs.
        if ~strcmp(info.name, A.name)
            problems{end + 1} = sprintf('name "%s" vs "%s"', info.name, A.name); %#ok<AGROW>
        end
        if ~isequal(info.freq_range(:), A.freq_range(:))
            problems{end + 1} = 'frequency range differs'; %#ok<AGROW>
        end
        meta = as_cell(A.params);
        for k = 1:numel(meta)
            if ~isfield(info.defaults, meta{k}.id) || info.defaults.(meta{k}.id) ~= meta{k}.default
                problems{end + 1} = sprintf('default of %s differs', meta{k}.id); %#ok<AGROW>
            end
        end

        % S11 trace (only stored for some antennas).
        if isfield(A, 'curve')
            out = antenna_model(A.key, A.curve.params);
            [~, s11] = antenna_s11_curve(A.key, out, info.freq_range);
            if numel(s11) ~= numel(A.curve.s11) || max(abs(s11 - A.curve.s11(:))) > 1e-9
                problems{end + 1} = 'S11 trace differs'; %#ok<AGROW>
            end
        end

        if isempty(problems)
            fprintf('  PASS  %-16s %3d cases\n', A.key, numel(cases));
        else
            fprintf('  FAIL  %-16s %s\n', A.key, strjoin(problems, '; '));
        end
        total_fail = total_fail + numel(problems);
    end

    ok = total_fail == 0;
    if ok
        fprintf('ALL PASS - %d values match (worst relative difference %.2g)\n', total_values, worst);
    else
        fprintf('%d mismatches - MATLAB and dashboard engines differ\n', total_fail);
    end
end

function c = as_cell(x)
%AS_CELL  jsondecode gives struct arrays or cells (when fields differ).
    if iscell(x)
        c = x(:)';
    else
        c = num2cell(x(:)');
    end
end
