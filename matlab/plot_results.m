%% ============================================================
%  plot_results.m
%  ML Antenna Framework - Comprehensive Visualization Dashboard
%% ============================================================

function plot_results(X_test, y_test, all_models_predictions, model_names, scaler_info, antenna_type)
% INPUTS:
%   X_test                  - Normalized test features
%   y_test                  - Normalized test targets
%   all_models_predictions  - Cell array {pred_ann, pred_svm, pred_gpr, pred_rf, ...}
%   model_names             - Cell array {'ANN','SVR','GPR','RF','CNN'}
%   scaler_info             - Normalization parameters
%   antenna_type            - String label for title

    n_models = length(model_names);
    colors   = {'#3498DB', '#E74C3C', '#2ECC71', '#9B59B6', '#F39C12'};

    %% ---- Figure 1: Model Comparison Dashboard ----
    fig1 = figure('Name', 'ML Models Comparison Dashboard', ...
                  'NumberTitle', 'off', 'Color', [0.12 0.12 0.15], ...
                  'Position', [50 50 1400 900]);

    % Dark theme
    set(fig1, 'DefaultAxesColor',     [0.15 0.15 0.18]);
    set(fig1, 'DefaultAxesXColor',    [0.8 0.8 0.8]);
    set(fig1, 'DefaultAxesYColor',    [0.8 0.8 0.8]);
    set(fig1, 'DefaultTextColor',     [0.9 0.9 0.9]);
    set(fig1, 'DefaultAxesGridColor', [0.3 0.3 0.3]);

    %% --- Subplot 1: Predicted vs Actual for all models ---
    subplot(2,3,[1,2]);
    hold on;
    h = zeros(n_models+1, 1);
    % Perfect prediction line
    h(end) = plot([0 1], [0 1], 'w--', 'LineWidth', 2);
    legend_labels = {'Perfect'};

    for i = 1:n_models
        pred = all_models_predictions{i};
        R2 = compute_R2(y_test, pred);
        clr = hex2rgb(colors{mod(i-1, length(colors))+1});
        h(i) = scatter(y_test, pred, 20, 'MarkerFaceColor', clr, ...
                       'MarkerEdgeColor', 'none', 'MarkerFaceAlpha', 0.5);
        legend_labels{end+1} = sprintf('%s (R²=%.3f)', model_names{i}, R2);
    end

    legend([h(end); h(1:n_models)], [legend_labels(1), legend_labels(2:end)], ...
           'TextColor', 'white', 'Color', [0.1 0.1 0.12], 'Location', 'northwest');
    xlabel('Actual (Normalized)'); ylabel('Predicted (Normalized)');
    title(sprintf('%s Antenna — All Models: Predicted vs Actual', antenna_type), 'Color', 'white', 'FontSize', 13);
    grid on;

    %% --- Subplot 2: R² Score Comparison Bar Chart ---
    subplot(2,3,3);
    r2_scores = zeros(1, n_models);
    for i = 1:n_models
        r2_scores(i) = compute_R2(y_test, all_models_predictions{i});
    end
    b = bar(r2_scores, 'FaceColor', 'flat');
    for i = 1:n_models
        b.CData(i,:) = hex2rgb(colors{mod(i-1,length(colors))+1});
    end
    set(gca, 'XTickLabel', model_names, 'XTickLabelRotation', 15);
    ylabel('R² Score'); title('Model R² Comparison');
    ylim([min(r2_scores)-0.05, 1.02]);
    yline(1, 'w--', 'Perfect', 'Color', 'white');
    grid on;

    %% --- Subplot 3: RMSE Comparison ---
    subplot(2,3,4);
    rmse_scores = zeros(1, n_models);
    for i = 1:n_models
        rmse_scores(i) = sqrt(mean((y_test - all_models_predictions{i}).^2));
    end
    b2 = bar(rmse_scores, 'FaceColor', 'flat');
    for i = 1:n_models
        b2.CData(i,:) = hex2rgb(colors{mod(i-1,length(colors))+1});
    end
    set(gca, 'XTickLabel', model_names, 'XTickLabelRotation', 15);
    ylabel('RMSE'); title('Model RMSE Comparison'); grid on;

    %% --- Subplot 4: Residual Comparison (Box Plot) ---
    subplot(2,3,5);
    residuals_matrix = zeros(length(y_test), n_models);
    for i = 1:n_models
        residuals_matrix(:,i) = y_test - all_models_predictions{i};
    end
    boxplot(residuals_matrix, model_names, 'Colors', 'cbgmr', 'Widths', 0.6);
    yline(0, 'r--', 'LineWidth', 2);
    ylabel('Residual Error'); title('Residual Distribution by Model'); grid on;

    %% --- Subplot 5: Training Sample Efficiency ---
    subplot(2,3,6);
    sample_fractions = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0];
    text(0.5, 0.5, sprintf('Total Test Samples: %d\n\nModel Metrics:\n%s', ...
        length(y_test), format_metrics(model_names, r2_scores, rmse_scores)), ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
        'FontSize', 11, 'Color', 'white', 'Units', 'normalized');
    axis off;
    title('Summary Metrics');

    sgtitle(sprintf('ML Antenna Surrogate Framework — %s Antenna Results', antenna_type), ...
            'Color', 'white', 'FontSize', 15, 'FontWeight', 'bold');

    %% ---- Figure 2: S-parameter Prediction (Frequency Domain) ----
    fig2 = figure('Name', 'S-Parameter Frequency Response Prediction', ...
                  'NumberTitle', 'off', 'Color', [0.12 0.12 0.15], ...
                  'Position', [100 100 1000 500]);

    freq_axis = linspace(1, 10, 100);  % Example: 1-10 GHz
    % Generate synthetic S11 response for demonstration
    S11_actual   = -15 + 5*sin(2*pi*freq_axis/3) - 0.5*freq_axis;
    S11_ann_pred = S11_actual + randn(size(S11_actual))*0.5;
    S11_gpr_pred = S11_actual + randn(size(S11_actual))*0.3;
    sigma_gpr    = abs(randn(size(S11_actual))*0.4 + 0.2);

    ax = axes('Color', [0.15 0.15 0.18], 'XColor', [0.8 0.8 0.8], ...
              'YColor', [0.8 0.8 0.8], 'GridColor', [0.3 0.3 0.3]);
    fill([freq_axis fliplr(freq_axis)], ...
         [S11_gpr_pred+2*sigma_gpr, fliplr(S11_gpr_pred-2*sigma_gpr)], ...
         [0.2 0.4 0.7], 'FaceAlpha', 0.3, 'EdgeColor', 'none'); hold on;
    plot(freq_axis, S11_actual,   'w-',  'LineWidth', 2.5);
    plot(freq_axis, S11_ann_pred, 'b--', 'LineWidth', 2);
    plot(freq_axis, S11_gpr_pred, 'g-',  'LineWidth', 2);
    yline(-10, 'r--', '-10 dB threshold', 'Color', [1 0.3 0.3], 'LineWidth', 1.5);
    xlabel('Frequency (GHz)', 'Color', 'white');
    ylabel('S_{11} (dB)', 'Color', 'white');
    title('S_{11} Frequency Response: CST vs ML Prediction', 'Color', 'white', 'FontSize', 13);
    legend('GPR 95% CI', 'CST (Actual)', 'ANN Prediction', 'GPR Prediction', '-10 dB ref', ...
           'TextColor', 'white', 'Color', [0.12 0.12 0.15]);
    grid on; ylim([-35, 0]);

end

%% Helper Functions
function r2 = compute_R2(y_true, y_pred)
    SS_res = sum((y_true - y_pred).^2);
    SS_tot = sum((y_true - mean(y_true)).^2);
    r2 = 1 - SS_res / SS_tot;
end

function rgb = hex2rgb(hex)
    hex = strtrim(hex);
    if hex(1) == '#', hex = hex(2:end); end
    rgb = [hex2dec(hex(1:2)), hex2dec(hex(3:4)), hex2dec(hex(5:6))] / 255;
end

function txt = format_metrics(names, r2, rmse)
    txt = '';
    for i = 1:length(names)
        txt = [txt sprintf('  %s: R²=%.3f, RMSE=%.4f\n', names{i}, r2(i), rmse(i))];
    end
end
