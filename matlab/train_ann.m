%% ============================================================
%  train_ann.m
%  ML Antenna Framework - Artificial Neural Network Training
%  Uses MATLAB Neural Network Toolbox (feedforwardnet)
%% ============================================================

function [net, perf, predictions] = train_ann(X_train, y_train, X_test, y_test, options)
% INPUTS:
%   X_train, y_train - Training data
%   X_test,  y_test  - Test data
%   options - Struct with:
%       .hidden_layers  - e.g. [64 32 16]  (default)
%       .activation     - 'tansig' | 'logsig' | 'purelin'
%       .epochs         - Max training epochs (default: 1000)
%       .lr             - Learning rate (default: 0.001)
%       .regularization - L2 lambda (default: 1e-4)
%
% OUTPUTS:
%   net         - Trained MATLAB neural network object
%   perf        - Struct with R2, RMSE, MAE metrics
%   predictions - Predicted values on test set

    %% Default Options
    if nargin < 5 || isempty(options)
        options.hidden_layers  = [64 32 16];
        options.activation     = 'tansig';
        options.epochs         = 1000;
        options.lr             = 0.001;
        options.regularization = 1e-4;
    end

    fprintf('\n=== Artificial Neural Network (ANN) Training ===\n');
    fprintf('Architecture: %d -> ', size(X_train, 2));
    fprintf('%d -> ', options.hidden_layers);
    fprintf('1\n');
    fprintf('Activation: %s | Epochs: %d | LR: %g\n', ...
            options.activation, options.epochs, options.lr);

    %% Build Network
    net = feedforwardnet(options.hidden_layers, 'trainbr'); % Bayesian Regularization
    
    % Set activation functions for hidden layers
    for i = 1:length(options.hidden_layers)
        net.layers{i}.transferFcn = options.activation;
    end
    net.layers{end}.transferFcn = 'purelin'; % Linear output for regression

    %% Training Parameters
    net.trainParam.epochs     = options.epochs;
    net.trainParam.lr         = options.lr;
    net.trainParam.goal       = 1e-6;
    net.trainParam.max_fail   = 20;         % Early stopping patience
    net.trainParam.showWindow = true;       % Show training GUI
    net.performParam.regularization = options.regularization;

    %% Data Division
    net.divideParam.trainRatio = 0.80;
    net.divideParam.valRatio   = 0.10;
    net.divideParam.testRatio  = 0.10;

    %% Train
    tic;
    [net, tr] = train(net, X_train', y_train');
    train_time = toc;
    fprintf('Training completed in %.2f seconds\n', train_time);
    fprintf('Best validation performance: %.6f at epoch %d\n', tr.best_perf, tr.best_epoch);

    %% Evaluate on Test Set
    predictions = net(X_test')';
    perf = evaluate_model(y_test, predictions, 'ANN');

    %% Save Model
    save('ann_model.mat', 'net', 'perf', 'tr', 'options');
    fprintf('Model saved: ann_model.mat\n');

    %% Plot Training History
    figure('Name', 'ANN Training Results', 'NumberTitle', 'off', 'Color', 'white');
    
    subplot(2,2,1);
    semilogy(tr.epoch, tr.perf, 'b-', tr.epoch, tr.vperf, 'r--', 'LineWidth', 2);
    xlabel('Epoch'); ylabel('MSE Loss');
    legend('Training', 'Validation'); title('Learning Curve'); grid on;
    
    subplot(2,2,2);
    scatter(y_test, predictions, 30, 'filled', 'MarkerFaceAlpha', 0.6);
    hold on; plot([min(y_test) max(y_test)], [min(y_test) max(y_test)], 'r--', 'LineWidth', 2);
    xlabel('Actual'); ylabel('Predicted'); 
    title(sprintf('Predicted vs Actual (R²=%.4f)', perf.R2)); grid on;
    
    subplot(2,2,[3,4]);
    residuals = y_test - predictions;
    histogram(residuals, 30, 'FaceColor', '#4472C4', 'EdgeColor', 'white');
    xlabel('Residual Error'); ylabel('Count');
    title(sprintf('Residual Distribution (RMSE=%.4f, MAE=%.4f)', perf.RMSE, perf.MAE)); grid on;
    
    sgtitle('ANN Surrogate Model Performance', 'FontSize', 14, 'FontWeight', 'bold');

end

%% ============================================================
%  evaluate_model - Shared evaluation function
%% ============================================================
function perf = evaluate_model(y_true, y_pred, model_name)
    SS_res = sum((y_true - y_pred).^2);
    SS_tot = sum((y_true - mean(y_true)).^2);
    
    perf.R2   = 1 - SS_res / SS_tot;
    perf.RMSE = sqrt(mean((y_true - y_pred).^2));
    perf.MAE  = mean(abs(y_true - y_pred));
    perf.MAPE = mean(abs((y_true - y_pred) ./ (y_true + eps))) * 100;
    
    fprintf('\n--- %s Performance Metrics ---\n', model_name);
    fprintf('R² Score : %.4f\n', perf.R2);
    fprintf('RMSE     : %.4f\n', perf.RMSE);
    fprintf('MAE      : %.4f\n', perf.MAE);
    fprintf('MAPE     : %.2f%%\n', perf.MAPE);
end
