%% ============================================================
%  load_web_input.m
%  ML Antenna Framework - Ingest User Inputs from Web Dashboard / JSON
% ============================================================

function results = load_web_input(varargin)
% LOAD_WEB_INPUT Ingests antenna parameters from a JSON or CSV file exported
% from the web dashboard, executes CST co-simulation, and renders verification.
%
% USAGE:
%   load_web_input                         % Looks for data/user_input.json
%   load_web_input('path/to/params.json')

    script_dir = fileparts(mfilename('fullpath'));
    project_root = fullfile(script_dir, '..');
    
    if nargin >= 1 && ~isempty(varargin{1})
        target_file = varargin{1};
    else
        target_file = fullfile(project_root, 'data', 'user_input.json');
    end

    if ~exist(target_file, 'file')
        % Create sample user input file if none exists
        default_data = struct( ...
            'antenna', 'patch', ...
            'model', 'gpr', ...
            'params', struct('Length_mm', 29.4, 'Width_mm', 38.0, 'Height_mm', 1.6, 'Permittivity', 4.4));
        fid = fopen(target_file, 'w');
        if fid ~= -1
            fprintf(fid, '%s', jsonencode(default_data, 'PrettyPrint', true));
            fclose(fid);
            fprintf('Created initial input file: %s\n', target_file);
        end
    end

    fprintf('Loading user parameters from: %s\n', target_file);
    raw_text = fileread(target_file);
    cfg = jsondecode(raw_text);

    antenna_type = 'patch';
    if isfield(cfg, 'antenna'), antenna_type = cfg.antenna; end
    
    model_type = 'gpr';
    if isfield(cfg, 'model'), model_type = cfg.model; end

    param_vec = [];
    if isfield(cfg, 'params')
        fn = fieldnames(cfg.params);
        param_vec = zeros(1, length(fn));
        for i = 1:length(fn)
            param_vec(i) = cfg.params.(fn{i});
            fprintf('  %-20s: %.3f\n', fn{i}, param_vec(i));
        end
    end

    % Run verification with loaded inputs
    results = cst_matlab_verify(antenna_type, model_type, param_vec);
end
