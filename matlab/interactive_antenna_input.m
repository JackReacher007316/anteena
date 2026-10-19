%% ============================================================
%  interactive_antenna_input.m
%  ML Antenna Framework - Interactive User Input & CST-MATLAB Co-Simulation
%  Prompts the user for antenna topology, physical dimensions, or target
%  specifications, connects to CST Studio Suite, and verifies live in MATLAB.
% ============================================================

function results = interactive_antenna_input()
% INTERACTIVE_ANTENNA_INPUT Prompts user via GUI dialog or Command Window,
% passes parameters to CST Studio Suite and ML Surrogate Models, and renders
% the live verification dashboard.
%
% USAGE:
%   interactive_antenna_input       % Launches interactive session

    fprintf('\n╔══════════════════════════════════════════════════════════════════╗\n');
    fprintf('║     ML ANTENNA FRAMEWORK: INTERACTIVE USER INPUT & CO-SIM        ║\n');
    fprintf('╚══════════════════════════════════════════════════════════════════╝\n\n');

    %% 1. Antenna Topology Selection
    antennas = {
        'Patch (Microstrip)', ...
        'MIMO (2-Port PIFA)', ...
        'UWB (CPW-Fed Monopole)', ...
        '5G mmWave Phased Array (28 GHz)', ...
        'Fractal (Sierpinski Carpet)', ...
        'Horn (Pyramidal)', ...
        'Dipole (Half-Wave)', ...
        'Bow-Tie Antenna'
    };

    antenna_keys = {'patch', 'mimo', 'uwb', '5g', 'fractal', 'horn', 'dipole', 'bowtie'};

    % Detect if MATLAB has graphical desktop enabled
    has_gui = usejava('desktop') && usejava('awt');
    
    sel_idx = 1;
    if has_gui
        [sel_idx, ok] = listdlg('PromptString', 'Select Antenna Topology:', ...
                                'SelectionMode', 'single', ...
                                'ListString', antennas, ...
                                'InitialValue', 1, ...
                                'Name', 'Antenna Type Selection', ...
                                'ListSize', [280, 200]);
        if ~ok || isempty(sel_idx), sel_idx = 1; end
    else
        fprintf('--- Available Antenna Topologies ---\n');
        for i = 1:length(antennas)
            fprintf('  [%d] %s\n', i, antennas{i});
        end
        user_choice = input('Select antenna topology [1-8, default 1]: ', 's');
        val = str2double(user_choice);
        if ~isnan(val) && val >= 1 && val <= length(antennas)
            sel_idx = val;
        end
    end

    selected_antenna = antenna_keys{sel_idx};
    fprintf('\n>> Selected Antenna: %s\n', antennas{sel_idx});

    %% 2. ML Model Selection
    models = {'Gaussian Process Regression (GPR)', ...
              'Support Vector Regression (SVR)', ...
              'Artificial Neural Network (ANN)', ...
              'Random Forest (RF)'};
    model_keys = {'gpr', 'svm', 'ann', 'rf'};

    model_idx = 1;
    if has_gui
        [model_idx, ok_m] = listdlg('PromptString', 'Select ML Surrogate Architecture:', ...
                                    'SelectionMode', 'single', ...
                                    'ListString', models, ...
                                    'InitialValue', 1, ...
                                    'Name', 'ML Model Selection', ...
                                    'ListSize', [280, 140]);
        if ~ok_m || isempty(model_idx), model_idx = 1; end
    else
        fprintf('\n--- Available ML Surrogate Models ---\n');
        for i = 1:length(models)
            fprintf('  [%d] %s\n', i, models{i});
        end
        user_choice_m = input('Select ML model [1-4, default 1]: ', 's');
        val_m = str2double(user_choice_m);
        if ~isnan(val_m) && val_m >= 1 && val_m <= length(models)
            model_idx = val_m;
        end
    end

    selected_model = model_keys{model_idx};
    fprintf('>> Selected Model: %s\n\n', models{model_idx});

    %% 3. Prompt User for Physical Parameters
    param_names = {};
    defaults = {};
    units = {};

    switch selected_antenna
        case 'patch'
            param_names = {'Patch Length (L)', 'Patch Width (W)', 'Substrate Height (H)', 'Substrate Permittivity (eps_r)'};
            defaults    = {'29.4', '38.0', '1.6', '4.4'};
            units       = {'mm', 'mm', 'mm', 'relative'};
            f0_estimate = @(p) 299.792458 / (2 * (p(1) + 2*0.412*p(3)*((p(4)+1)/2 + 0.3)/(p(4)+0.8)) * sqrt((p(4)+1)/2));

        case 'mimo'
            param_names = {'PIFA Length', 'PIFA Width', 'Element Spacing', 'Substrate Permittivity'};
            defaults    = {'24.0', '12.0', '20.0', '4.4'};
            units       = {'mm', 'mm', 'mm', 'relative'};
            f0_estimate = @(p) 2.45 * (24.0 / p(1)) * sqrt(4.4 / p(4));

        case 'uwb'
            param_names = {'Slot Width', 'Slot Length', 'Ground Cutout', 'Feed Gap'};
            defaults    = {'16.0', '22.0', '12.5', '0.5'};
            units       = {'mm', 'mm', 'mm', 'mm'};
            f0_estimate = @(p) 3.1 + 80.0 / (p(1) + p(2));

        case '5g'
            param_names = {'Element Spacing (dx)', 'Element Spacing (dy)', 'Patch Length', 'Array Count'};
            defaults    = {'5.35', '5.35', '2.80', '4'};
            units       = {'mm (0.5 lambda)', 'mm', 'mm', 'elements'};
            f0_estimate = @(p) 28.0 * (2.80 / p(3));

        case 'fractal'
            param_names = {'Base Length', 'Scale Factor', 'Iteration Order', 'Permittivity'};
            defaults    = {'40.0', '0.333', '2', '4.4'};
            units       = {'mm', 'ratio', 'order [0-2]', 'relative'};
            f0_estimate = @(p) 2.45 * (40.0 / p(1));

        otherwise
            param_names = {'Radiator Length', 'Radiator Width', 'Height', 'Permittivity'};
            defaults    = {'30.0', '25.0', '1.6', '4.4'};
            units       = {'mm', 'mm', 'mm', 'relative'};
            f0_estimate = @(p) 2.45;
    end

    params_entered = zeros(1, length(param_names));

    if has_gui
        prompt_labels = cell(1, length(param_names));
        for i = 1:length(param_names)
            prompt_labels{i} = sprintf('%s [%s]:', param_names{i}, units{i});
        end
        dlgtitle = sprintf('Enter Parameters for %s', antennas{sel_idx});
        dims = [1 55];
        answer = inputdlg(prompt_labels, dlgtitle, dims, defaults);

        if isempty(answer)
            fprintf('Dialog cancelled. Using default antenna dimensions.\n');
            answer = defaults;
        end

        for i = 1:length(answer)
            v = str2double(answer{i});
            if isnan(v), v = str2double(defaults{i}); end
            params_entered(i) = v;
        end
    else
        fprintf('--- Enter Antenna Dimensions (Press Enter for Default) ---\n');
        for i = 1:length(param_names)
            u_in = input(sprintf('  %-28s [%s] (Default %s): ', param_names{i}, units{i}, defaults{i}), 's');
            if isempty(strtrim(u_in))
                params_entered(i) = str2double(defaults{i});
            else
                v = str2double(u_in);
                if isnan(v), v = str2double(defaults{i}); end
                params_entered(i) = v;
            end
        end
    end

    fprintf('\n══════════════════════════════════════════════════════════════════\n');
    fprintf('                    CONFIRMED USER INPUTS                         \n');
    fprintf('══════════════════════════════════════════════════════════════════\n');
    for i = 1:length(param_names)
        fprintf('  %-32s = %8.3f %s\n', param_names{i}, params_entered(i), units{i});
    end
    fprintf('══════════════════════════════════════════════════════════════════\n\n');

    %% 4. Connect to CST Studio Suite via COM
    fprintf('[Step 1/3] Connecting to CST Studio Suite COM Server...\n');
    cst_bridge = cst_matlab_connect();

    %% 5. Execute CST 3D & ML Surrogate Verification
    fprintf('\n[Step 2/3] Simulating with User Inputs on CST & ML...\n');
    
    % Call cst_matlab_verify with user's custom antenna, model, and parameters
    results = cst_matlab_verify(selected_antenna, selected_model, params_entered);

    %% 6. Enhance the Active MATLAB Figure with User Input Badges
    hFig = gcf;
    if ~isempty(hFig)
        set(hFig, 'Name', sprintf('Verification: %s [USER INPUTS APPLIED]', antennas{sel_idx}));
        
        % Annotate parameter string on figure
        param_str_list = {};
        for i = 1:length(param_names)
            param_str_list{end+1} = sprintf('%s: %.2f %s', param_names{i}, params_entered(i), units{i});
        end
        param_summary_str = strjoin(param_str_list, '  |  ');

        % Add an annotation banner at the bottom of the figure
        annotation('textbox', [0.08 0.01 0.84 0.035], ...
                   'String', ['User Input Parameters:  ' param_summary_str], ...
                   'EdgeColor', [0.22 0.70 1.00], ...
                   'BackgroundColor', [0.12 0.13 0.18], ...
                   'Color', [0.9 0.95 1.0], ...
                   'FontSize', 9.5, ...
                   'FontWeight', 'bold', ...
                   'HorizontalAlignment', 'center', ...
                   'VerticalAlignment', 'middle');
    end

    fprintf('[Step 3/3] Live Verification Completed! Figure is active in MATLAB.\n');
end
