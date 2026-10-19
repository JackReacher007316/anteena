%% ============================================================
%  train_random_forest.m
%  ML Antenna Framework - Random Forest Regression (TreeBagger)
%% ============================================================

function [rf_model, perf, predictions, importance] = train_random_forest(X_train, y_train, X_test, y_test, options)
% INPUTS:
%   X_train, y_train - Training data
%   X_test,  y_test  - Test data
%   options:
%       .n_trees     - Number of trees (default: 200)
%       .min_leaf    - Minimum leaf size (default: 5)
%       .n_features  - Features sampled per split (default: auto = sqrt(n))
%       .oob_pred    - Enable out-of-bag prediction (default: true)

    if nargin < 5 || isempty(options)
        options.n_trees    = 200;
        options.min_leaf   = 5;
        options.n_features = 'all';
        options.oob_pred   = true;
    end

    fprintf('\n=== Random Forest Regression Training ===\n');
    fprintf('Trees: %d | MinLeaf: %d | OOB: %s\n', ...
            options.n_trees, options.min_leaf, mat2str(options.oob_pred));

    %% Train Random Forest (TreeBagger)
    tic;
    rf_model = TreeBagger(options.n_trees, X_train, y_train, ...
        'Method',          'regression', ...
        'MinLeafSize',     options.min_leaf, ...
        'NumPredictorsToSample', options.n_features, ...
        'OOBPrediction',   'on', ...
        'OOBPredictorImportance', 'on', ...
        'Surrogate',       'off', ...
        'NumPrint',        50);  % Print progress every 50 trees
    train_time = toc;
    fprintf('RF training completed in %.2f seconds\n', train_time);

    %% OOB Error Curve
    oob_error = oobError(rf_model);
    fprintf('Final OOB MSE: %.6f (at %d trees)\n', oob_error(end), options.n_trees);

    %% Feature Importance
    importance = rf_model.OOBPermutedPredictorDeltaError;
    [sorted_imp, sort_idx] = sort(importance, 'descend');

    fprintf('\n--- Feature Importance (OOB Permutation) ---\n');
    for i = 1:length(importance)
        fprintf('  Feature %d: %.4f\n', sort_idx(i), sorted_imp(i));
    end

    %% Evaluate on Test Set
    predictions = predict(rf_model, X_test);
    perf = evaluate_model(y_test, predictions, 'Random Forest');

    %% Save
    save('rf_model.mat', 'rf_model', 'perf', 'importance', 'options');
    fprintf('Model saved: rf_model.mat\n');

    %% Plots
    figure('Name', 'Random Forest Results', 'NumberTitle', 'off', 'Color', 'white');

    subplot(2,2,1);
    plot(1:options.n_trees, oob_error, 'b-', 'LineWidth', 2);
    xlabel('Number of Trees'); ylabel('OOB MSE');
    title('OOB Error vs Number of Trees'); grid on;
    xline(find(oob_error == min(oob_error)), 'r--', 'Min OOB Error');

    subplot(2,2,2);
    barh(sorted_imp, 'FaceColor', '#2ECC71', 'EdgeColor', 'none');
    set(gca, 'YTick', 1:length(importance), 'YTickLabel', sort_idx);
    xlabel('Importance Score'); ylabel('Feature Index');
    title('Feature Importance (OOB Permutation)'); grid on;

    subplot(2,2,3);
    scatter(y_test, predictions, 40, 'filled', 'MarkerFaceColor', '#E67E22', 'MarkerFaceAlpha', 0.7);
    hold on; plot([0 1],[0 1], 'k--', 'LineWidth', 2);
    xlabel('Actual'); ylabel('Predicted');
    title(sprintf('Predicted vs Actual (R²=%.4f)', perf.R2)); grid on;

    subplot(2,2,4);
    residuals = y_test - predictions;
    histogram(residuals, 30, 'FaceColor', '#8E44AD', 'EdgeColor', 'white');
    xline(0, 'r--', 'LineWidth', 2);
    xlabel('Residual'); ylabel('Frequency');
    title(sprintf('Residuals (RMSE=%.4f)', perf.RMSE)); grid on;

    sgtitle('Random Forest Surrogate Model Performance', 'FontSize', 13, 'FontWeight', 'bold');

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
