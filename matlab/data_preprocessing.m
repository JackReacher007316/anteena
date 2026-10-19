%% ============================================================
%  data_preprocessing.m
%  ML Antenna Framework - Data Preprocessing Module
%  Loads raw CST exports, cleans, normalizes, and splits data
%% ============================================================

function [X_train, X_test, y_train, y_test, scaler_info] = data_preprocessing(filepath, target_col, test_ratio)
% INPUTS:
%   filepath   - Path to CSV file (CST export)
%   target_col - Column name(s) of output(s): 'S11_dB', 'Gain_dBi', 'Bandwidth_GHz'
%   test_ratio - Fraction for test set (default: 0.2)
%
% OUTPUTS:
%   X_train, X_test  - Feature matrices
%   y_train, y_test  - Target vectors
%   scaler_info      - Struct with normalization params (for inverse transform)

    if nargin < 3, test_ratio = 0.2; end
    if nargin < 2, target_col = 'S11_dB'; end

    fprintf('=== Antenna Data Preprocessing ===\n');
    fprintf('Loading: %s\n', filepath);

    %% 1. Load Data
    data = readtable(filepath);
    fprintf('Loaded %d samples, %d columns\n', height(data), width(data));

    %% 2. Detect Antenna Type from File Name
    if contains(filepath, 'patch')
        feature_cols = {'Length_mm', 'Width_mm', 'Height_mm', 'Permittivity'};
        antenna_type = 'Patch/Microstrip';
    elseif contains(filepath, 'mimo')
        feature_cols = {'Spacing_lambda', 'Length_mm'};
        antenna_type = 'MIMO';
    elseif contains(filepath, 'uwb')
        feature_cols = {'SlotWidth_mm', 'SlotLength_mm', 'GndCutout_mm', 'FeedGap_mm'};
        antenna_type = 'UWB';
    else
        % Auto-detect: all columns except target
        all_cols = data.Properties.VariableNames;
        feature_cols = all_cols(~ismember(all_cols, {target_col}));
        antenna_type = 'Generic';
    end

    fprintf('Antenna Type: %s\n', antenna_type);
    fprintf('Features: %s\n', strjoin(feature_cols, ', '));
    fprintf('Target: %s\n', target_col);

    %% 3. Remove NaN / Inf rows
    X_raw = data{:, feature_cols};
    y_raw = data{:, target_col};
    valid_mask = all(~isnan(X_raw) & ~isinf(X_raw), 2) & ~isnan(y_raw) & ~isinf(y_raw);
    X_raw = X_raw(valid_mask, :);
    y_raw = y_raw(valid_mask);
    removed = sum(~valid_mask);
    if removed > 0
        fprintf('Removed %d invalid rows (NaN/Inf)\n', removed);
    end

    %% 4. Outlier Removal (IQR method on target)
    Q1 = prctile(y_raw, 25);
    Q3 = prctile(y_raw, 75);
    IQR_val = Q3 - Q1;
    outlier_mask = y_raw >= (Q1 - 3 * IQR_val) & y_raw <= (Q3 + 3 * IQR_val);
    X_raw = X_raw(outlier_mask, :);
    y_raw = y_raw(outlier_mask);
    fprintf('Removed %d outliers (3-IQR method)\n', sum(~outlier_mask));

    %% 5. Normalization (Min-Max to [0,1])
    X_min = min(X_raw);
    X_max = max(X_raw);
    X_norm = (X_raw - X_min) ./ (X_max - X_min + eps);

    y_min = min(y_raw);
    y_max = max(y_raw);
    y_norm = (y_raw - y_min) / (y_max - y_min + eps);

    % Save scaler info for inverse transform
    scaler_info.X_min = X_min;
    scaler_info.X_max = X_max;
    scaler_info.y_min = y_min;
    scaler_info.y_max = y_max;
    scaler_info.feature_cols = feature_cols;
    scaler_info.target_col = target_col;
    scaler_info.antenna_type = antenna_type;

    %% 6. Train/Test Split (stratified-like random split)
    N = size(X_norm, 1);
    rng(42); % reproducibility
    idx = randperm(N);
    n_test = round(N * test_ratio);
    test_idx  = idx(1:n_test);
    train_idx = idx(n_test+1:end);

    X_train = X_norm(train_idx, :);
    X_test  = X_norm(test_idx,  :);
    y_train = y_norm(train_idx);
    y_test  = y_norm(test_idx);

    fprintf('\n--- Data Split ---\n');
    fprintf('Training samples : %d (%.0f%%)\n', length(train_idx), (1-test_ratio)*100);
    fprintf('Test samples     : %d (%.0f%%)\n', length(test_idx),  test_ratio*100);
    fprintf('Feature dimensions: %d\n', size(X_train, 2));

    %% 7. Correlation Analysis
    fprintf('\n--- Pearson Correlation with Target ---\n');
    for i = 1:length(feature_cols)
        r = corr(X_raw(:,i), y_raw);
        fprintf('  %s: r = %.4f\n', feature_cols{i}, r);
    end

    %% 8. Save processed data
    out_dir = fileparts(filepath);
    out_dir = strrep(out_dir, 'raw', 'processed');
    if ~exist(out_dir, 'dir'), mkdir(out_dir); end
    
    processed_file = fullfile(out_dir, ['processed_' target_col '.mat']);
    save(processed_file, 'X_train', 'X_test', 'y_train', 'y_test', 'scaler_info');
    fprintf('\nSaved processed data to: %s\n', processed_file);

end
