%% ============================================================
%  train_gpr.m
%  ML Antenna Framework - Gaussian Process Regression (GPR)
%  Provides uncertainty quantification for antenna predictions
%% ============================================================

function [gpr_model, perf, predictions, sigma] = train_gpr(X_train, y_train, X_test, y_test, options)
% INPUTS:
%   X_train, y_train - Training data
%   X_test,  y_test  - Test data
%   options:
%       .kernel    - 'squaredexponential' | 'matern52' | 'ardsquaredexponential'
%       .optimize  - true/false (optimize hyperparameters)
%
% OUTPUTS:
%   gpr_model   - Trained GPR model
%   perf        - Performance metrics
%   predictions - Point predictions on test set
%   sigma       - Standard deviation (uncertainty) of predictions

    if nargin < 5 || isempty(options)
        options.kernel   = 'ardsquaredexponential'; % ARD = feature importance
        options.optimize = true;
        options.fit_method = 'exact';
        options.predict_method = 'exact';
    end

    fprintf('\n=== Gaussian Process Regression (GPR) Training ===\n');
    fprintf('Kernel: %s | Optimization: %s\n', options.kernel, mat2str(options.optimize));

    %% Train GPR
    tic;
    if options.optimize
        gpr_model = fitrgp(X_train, y_train, ...
            'KernelFunction', options.kernel, ...
            'FitMethod', options.fit_method, ...
            'PredictMethod', options.predict_method, ...
            'Standardize', true, ...
            'OptimizeHyperparameters', 'all', ...
            'HyperparameterOptimizationOptions', struct( ...
                'AcquisitionFunctionName', 'expected-improvement-plus', ...
                'MaxObjectiveEvaluations', 25, ...
                'ShowPlots', false, ...
                'Verbose', 0));
    else
        gpr_model = fitrgp(X_train, y_train, ...
            'KernelFunction', options.kernel, ...
            'Standardize', true);
    end
    train_time = toc;
    fprintf('GPR training completed in %.2f seconds\n', train_time);

    %% Predict with Uncertainty
    [predictions, ~, sigma] = predict(gpr_model, X_test);
    perf = evaluate_model(y_test, predictions, 'GPR');
    
    % Average prediction uncertainty
    fprintf('Mean Prediction Std Dev: %.4f\n', mean(sigma));

    %% ARD Feature Importance (if ARD kernel)
    if contains(options.kernel, 'ard')
        fprintf('\n--- Feature Importance (ARD Length Scales) ---\n');
        ls = gpr_model.KernelInformation.KernelParameters(1:end-1);
        for i = 1:length(ls)
            fprintf('  Feature %d: length_scale = %.4f (lower = more important)\n', i, ls(i));
        end
    end

    %% Save
    save('gpr_model.mat', 'gpr_model', 'perf', 'sigma', 'options');
    fprintf('Model saved: gpr_model.mat\n');

    %% Plot with Uncertainty Bands
    figure('Name', 'GPR with Uncertainty Quantification', 'NumberTitle', 'off', 'Color', 'white');

    subplot(2,2,[1,2]);
    [sorted_actual, idx] = sort(y_test);
    sorted_pred  = predictions(idx);
    sorted_sigma = sigma(idx);
    x_axis = 1:length(sorted_actual);
    
    fill([x_axis fliplr(x_axis)], ...
         [sorted_pred+2*sorted_sigma; flipud(sorted_pred-2*sorted_sigma)]', ...
         [0.7 0.85 1], 'EdgeColor', 'none', 'FaceAlpha', 0.6); hold on;
    plot(x_axis, sorted_actual, 'ko-', 'MarkerSize', 4, 'LineWidth', 1.5);
    plot(x_axis, sorted_pred, 'b-', 'LineWidth', 2);
    legend('95% CI', 'Actual', 'GPR Mean', 'Location', 'best');
    xlabel('Sorted Sample'); ylabel('Value (normalized)');
    title(sprintf('GPR Predictions with 95%% Confidence Interval (R²=%.4f)', perf.R2));
    grid on;

    subplot(2,2,3);
    scatter(y_test, predictions, 30, sigma, 'filled');
    colorbar; colormap('jet'); caxis([0, max(sigma)]);
    hold on; plot([0 1], [0 1], 'r--', 'LineWidth', 2);
    xlabel('Actual'); ylabel('Predicted');
    title('Predicted vs Actual (color = uncertainty)'); grid on;

    subplot(2,2,4);
    histogram(sigma, 25, 'FaceColor', '#9B59B6');
    xlabel('Prediction Std Dev σ'); ylabel('Count');
    title('Prediction Uncertainty Distribution'); grid on;

    sgtitle('GPR Surrogate Model - Uncertainty Quantification', 'FontSize', 13, 'FontWeight', 'bold');

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
