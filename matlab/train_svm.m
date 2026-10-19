%% ============================================================
%  train_svm.m
%  ML Antenna Framework - Support Vector Regression (SVR) Training
%  Uses MATLAB Statistics & Machine Learning Toolbox
%% ============================================================

function [svr_model, perf, predictions] = train_svm(X_train, y_train, X_test, y_test, options)
% INPUTS:
%   X_train, y_train - Training data (normalized)
%   X_test,  y_test  - Test data (normalized)
%   options - Struct with:
%       .kernel    - 'rbf' | 'polynomial' | 'linear' (default: 'rbf')
%       .C         - Regularization parameter (default: optimized via CV)
%       .epsilon   - Epsilon-insensitive loss tube (default: auto)
%       .optimize  - Use Bayesian hyperparameter optimization (default: true)

    if nargin < 5 || isempty(options)
        options.kernel   = 'rbf';
        options.C        = [];   % Auto-optimize
        options.epsilon  = [];   % Auto-optimize
        options.optimize = true;
    end

    fprintf('\n=== Support Vector Regression (SVR) Training ===\n');
    fprintf('Kernel: %s | Optimization: %s\n', options.kernel, mat2str(options.optimize));

    %% Map kernel names
    switch lower(options.kernel)
        case 'rbf',        kernel_fn = 'gaussian';
        case 'polynomial', kernel_fn = 'polynomial';
        case 'linear',     kernel_fn = 'linear';
        otherwise,         kernel_fn = 'gaussian';
    end

    %% Train SVR
    tic;
    if options.optimize
        fprintf('Running Bayesian hyperparameter optimization (may take 2-3 min)...\n');
        svr_model = fitrsvm(X_train, y_train, ...
            'KernelFunction', kernel_fn, ...
            'Standardize', true, ...
            'OptimizeHyperparameters', {'BoxConstraint', 'Epsilon', 'KernelScale'}, ...
            'HyperparameterOptimizationOptions', struct( ...
                'AcquisitionFunctionName', 'expected-improvement-plus', ...
                'MaxObjectiveEvaluations', 30, ...
                'ShowPlots', false, ...
                'Verbose', 0));
    else
        C_val = 1; eps_val = 0.05;
        if ~isempty(options.C),       C_val   = options.C; end
        if ~isempty(options.epsilon), eps_val = options.epsilon; end
        svr_model = fitrsvm(X_train, y_train, ...
            'KernelFunction', kernel_fn, ...
            'BoxConstraint',  C_val, ...
            'Epsilon',        eps_val, ...
            'Standardize',    true);
    end
    train_time = toc;
    fprintf('SVR training completed in %.2f seconds\n', train_time);

    %% Cross-validation Loss
    cv_model = crossval(svr_model, 'KFold', 5);
    cv_mse = kfoldLoss(cv_model);
    fprintf('5-Fold CV MSE: %.6f\n', cv_mse);

    %% Evaluate on Test Set
    predictions = predict(svr_model, X_test);
    perf = evaluate_model(y_test, predictions, 'SVR');

    %% Save
    save('svm_model.mat', 'svr_model', 'perf', 'options');
    fprintf('Model saved: svm_model.mat\n');

    %% Plot
    figure('Name', 'SVR Training Results', 'NumberTitle', 'off', 'Color', 'white');

    subplot(1,2,1);
    scatter(y_test, predictions, 40, 'filled', 'MarkerFaceColor', '#E74C3C', 'MarkerFaceAlpha', 0.6);
    hold on;
    lims = [min([y_test; predictions]) max([y_test; predictions])];
    plot(lims, lims, 'k--', 'LineWidth', 2);
    xlabel('Actual (Normalized)'); ylabel('Predicted (Normalized)');
    title(sprintf('SVR: Predicted vs Actual\nR² = %.4f', perf.R2)); grid on;

    subplot(1,2,2);
    residuals = y_test - predictions;
    [sorted_res, sort_idx] = sort(residuals);
    bar(sorted_res, 'FaceColor', '#27AE60', 'EdgeColor', 'none');
    hold on; yline(0, 'r--', 'LineWidth', 1.5);
    xlabel('Sample Index (sorted)'); ylabel('Residual');
    title(sprintf('Residuals\nRMSE=%.4f | MAE=%.4f', perf.RMSE, perf.MAE)); grid on;

    sgtitle('SVR Surrogate Model Performance', 'FontSize', 13, 'FontWeight', 'bold');

end

function perf = evaluate_model(y_true, y_pred, model_name)
    SS_res = sum((y_true - y_pred).^2);
    SS_tot = sum((y_true - mean(y_true)).^2);
    perf.R2   = 1 - SS_res / SS_tot;
    perf.RMSE = sqrt(mean((y_true - y_pred).^2));
    perf.MAE  = mean(abs(y_true - y_pred));
    perf.MAPE = mean(abs((y_true - y_pred) ./ (y_true + eps))) * 100;
    fprintf('\n--- %s Performance ---\n', model_name);
    fprintf('R²=%.4f | RMSE=%.4f | MAE=%.4f | MAPE=%.2f%%\n', ...
            perf.R2, perf.RMSE, perf.MAE, perf.MAPE);
end
