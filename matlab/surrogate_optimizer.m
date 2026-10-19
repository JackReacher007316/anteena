%% ============================================================
%  surrogate_optimizer.m
%  ML Antenna Framework - Surrogate-Based Antenna Optimizer
%  Uses trained ML model + Genetic Algorithm for optimization
%% ============================================================

function [best_params, best_performance] = surrogate_optimizer(antenna_type, model_type, targets, bounds)
% INPUTS:
%   antenna_type - 'patch' | 'mimo' | 'uwb' | '5g' | 'fractal'
%   model_type   - 'ann' | 'svm' | 'gpr' | 'rf' | 'best'
%   targets      - Struct with desired specs:
%                  .S11_dB     (e.g. -20 dB)
%                  .Gain_dBi   (e.g. 8 dBi)
%                  .BW_GHz     (e.g. 0.5 GHz)
%   bounds       - Struct with parameter bounds (from scaler_info)
%
% OUTPUTS:
%   best_params      - Optimal antenna dimensions [mm]
%   best_performance - Predicted performance at optimal design

    fprintf('\n╔══════════════════════════════════════════════╗\n');
    fprintf('║   ML-Based Antenna Surrogate Optimizer       ║\n');
    fprintf('╚══════════════════════════════════════════════╝\n');
    fprintf('Antenna Type : %s\n', antenna_type);
    fprintf('ML Model     : %s\n', model_type);

    %% Load Trained Models and Scaler Info
    [models, scaler_info] = load_models(antenna_type, model_type);

    %% Define Optimization Problem
    n_features = length(scaler_info.X_min);
    lb = zeros(1, n_features);   % Normalized lower bounds (always 0)
    ub = ones(1, n_features);    % Normalized upper bounds (always 1)

    %% Define Objective Function (Multi-objective weighted)
    % Weights for each target
    w_S11  = 0.5;   % Higher weight on return loss
    w_Gain = 0.3;
    w_BW   = 0.2;

    obj_fn = @(x) multi_objective(x, models, scaler_info, targets, w_S11, w_Gain, w_BW);

    %% --- Method 1: Genetic Algorithm ---
    fprintf('\n[1/3] Running Genetic Algorithm (GA)...\n');
    ga_opts = optimoptions('ga', ...
        'PopulationSize', 100, ...
        'MaxGenerations', 200, ...
        'EliteCount',     10, ...
        'CrossoverFraction', 0.8, ...
        'FunctionTolerance', 1e-6, ...
        'Display', 'iter', ...
        'PlotFcn', {@gaplotbestf, @gaplotdistance});

    [x_ga, fval_ga] = ga(obj_fn, n_features, [], [], [], [], lb, ub, [], ga_opts);

    %% --- Method 2: Particle Swarm Optimization ---
    fprintf('\n[2/3] Running Particle Swarm Optimization (PSO)...\n');
    pso_opts = optimoptions('particleswarm', ...
        'SwarmSize', 80, ...
        'MaxIterations', 500, ...
        'FunctionTolerance', 1e-7, ...
        'Display', 'iter');

    [x_pso, fval_pso] = particleswarm(obj_fn, n_features, lb, ub, pso_opts);

    %% --- Method 3: Bayesian Optimization over surrogate ---
    fprintf('\n[3/3] Running Bayesian Optimization...\n');
    vars = [];
    for i = 1:n_features
        vars = [vars, optimizableVariable(sprintf('x%d', i), [0, 1])];
    end
    bay_result = bayesopt(@(T) table2array(T) * obj_fn', vars, ...
        'MaxObjectiveEvaluations', 60, ...
        'AcquisitionFunctionName', 'expected-improvement-plus', ...
        'Verbose', 0, ...
        'PlotFcn', []);

    %% Select Best Solution
    [best_fval, best_method_idx] = min([fval_ga, fval_pso]);
    methods = {'GA', 'PSO'};
    x_solutions = [x_ga; x_pso];
    x_best_norm = x_solutions(best_method_idx, :);

    fprintf('\n=== Optimization Results ===\n');
    fprintf('Best method: %s (fval=%.6f)\n', methods{best_method_idx}, best_fval);

    %% Denormalize to Physical Parameters
    best_params = x_best_norm .* (scaler_info.X_max - scaler_info.X_min) + scaler_info.X_min;

    fprintf('\n--- Optimal Antenna Parameters ---\n');
    for i = 1:length(scaler_info.feature_cols)
        fprintf('  %s: %.4f mm\n', scaler_info.feature_cols{i}, best_params(i));
    end

    %% Predict Performance at Best Design
    best_performance = predict_all(x_best_norm, models, scaler_info);
    fprintf('\n--- Predicted Performance ---\n');
    fn = fieldnames(best_performance);
    for i = 1:length(fn)
        fprintf('  %s: %.4f\n', fn{i}, best_performance.(fn{i}));
    end

    %% Plot Optimization Convergence
    figure('Name', 'Optimization Convergence', 'Color', 'white');
    % Plot GA convergence if available
    title('Surrogate-Based Multi-Objective Optimization Convergence');
    xlabel('Generation / Iteration'); ylabel('Objective Function Value');
    grid on;

end

%% ============================================================
function cost = multi_objective(x, models, scaler_info, targets, w1, w2, w3)
    perf = predict_all(x, models, scaler_info);
    
    % Penalty functions (how far from target)
    e_S11  = max(0, perf.S11_dB  - targets.S11_dB)^2;   % Want S11 < target
    e_Gain = max(0, targets.Gain_dBi - perf.Gain_dBi)^2; % Want Gain > target
    e_BW   = max(0, targets.BW_GHz   - perf.BW_GHz)^2;   % Want BW > target

    cost = w1 * e_S11 + w2 * e_Gain + w3 * e_BW;
end

%% ============================================================
function perf = predict_all(x_norm, models, scaler_info)
    % Predict all antenna parameters using the loaded models
    if isfield(models, 'S11')
        y_S11  = predict_single(x_norm, models.S11,  scaler_info, 'S11_dB');
        y_Gain = predict_single(x_norm, models.Gain, scaler_info, 'Gain_dBi');
        y_BW   = predict_single(x_norm, models.BW,   scaler_info, 'BW_GHz');
    else
        % Single model predicts S11 only
        y_S11  = predict_single(x_norm, models.model, scaler_info, 'S11_dB');
        y_Gain = 0; y_BW = 0;
    end
    perf.S11_dB   = y_S11;
    perf.Gain_dBi = y_Gain;
    perf.BW_GHz   = y_BW;
end

%% ============================================================
function y_phys = predict_single(x_norm, model, scaler_info, target_name)
    if isa(model, 'network')  % ANN
        y_norm = model(x_norm')';
    elseif isa(model, 'RegressionSVM')
        y_norm = predict(model, x_norm);
    elseif isa(model, 'RegressionGP')
        y_norm = predict(model, x_norm);
    elseif isa(model, 'TreeBagger')
        y_norm = predict(model, x_norm);
    end
    % Denormalize
    y_phys = y_norm * (scaler_info.y_max - scaler_info.y_min) + scaler_info.y_min;
end

%% ============================================================
function [models, scaler_info] = load_models(antenna_type, model_type)
    model_file = sprintf('%s_model.mat', lower(model_type));
    if ~exist(model_file, 'file')
        error('Model file not found: %s. Run train_%s.m first.', model_file, model_type);
    end
    loaded = load(model_file);
    fn = fieldnames(loaded);
    % Find the model object
    for i = 1:length(fn)
        if ~isstruct(loaded.(fn{i})) && ~ischar(loaded.(fn{i}))
            models.model = loaded.(fn{i});
            break;
        end
    end
    % Load scaler
    proc_files = dir(fullfile('..', 'data', 'processed', ['*' antenna_type '*']));
    if isempty(proc_files)
        error('No processed data found for antenna type: %s', antenna_type);
    end
    proc_data = load(fullfile(proc_files(1).folder, proc_files(1).name));
    scaler_info = proc_data.scaler_info;
end
