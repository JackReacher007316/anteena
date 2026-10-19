function [out, info] = antenna_model(antenna, params)
%ANTENNA_MODEL  Closed-form EM engine for the dashboard's 30 antenna types.
%
%   out = antenna_model(antenna)           evaluates the default design
%   out = antenna_model(antenna, params)   params = struct of inputs, e.g.
%       antenna_model('patch', struct('length', 30, 'width', 38, ...
%                                     'height', 1.6, 'permittivity', 4.4))
%       Inputs that are not supplied keep their default value.
%   [out, info] = antenna_model(...)       also returns metadata:
%       info.key        antenna key, e.g. 'patch'
%       info.name       full antenna name
%       info.freq_range frequency span of the S11 chart [GHz]
%       info.defaults   default inputs (struct)
%       info.params     inputs actually used (defaults + supplied values)
%       info.missing    inputs that were not supplied (cellstr)
%       info.unknown    supplied fields this antenna does not use (cellstr)
%   keys = antenna_model('list')           cell array of supported antennas
%
%   OUT has the same fields as the web dashboard engine: S11 [dB],
%   Gain [dBi], BW [GHz], Fr [GHz] plus type-specific metrics (Isolation,
%   ECC, VSWR, efficiency, beamwidths, ...).
%
%   This is an independent MATLAB implementation of the dashboard engines
%   (dashboard/app.js, ANTENNA_CONFIGS.<type>.simulate). LIVE_VERIFY uses it
%   to check every number the dashboard shows, and TEST_ANTENNA_MODEL proves
%   that both implementations agree.
%
%   Example
%       [o, info] = antenna_model('dipole', struct('length', 60));
%       fprintf('%s: f0 = %.3f GHz, S11 = %.1f dB\n', info.name, o.Fr, o.S11);
%
%   See also LIVE_VERIFY, VERIFY_WEB_INPUT, ANTENNA_S11_CURVE.

    catalog = antenna_catalog();
    if nargin < 1 || isempty(antenna)
        antenna = 'patch';
    end
    antenna = lower(strtrim(char(antenna)));
    if strcmp(antenna, 'list')
        out = catalog(:, 1)';
        info = [];
        return;
    end

    row = find(strcmp(catalog(:, 1), antenna), 1);
    if isempty(row)
        error('antenna_model:unknownAntenna', ...
              'Unknown antenna type ''%s''. Supported types: %s', ...
              antenna, strjoin(catalog(:, 1)', ', '));
    end
    if nargin < 2
        params = struct();
    end

    % Defaults first, then overlay the supplied inputs.
    spec = catalog{row, 4};
    defaults = struct();
    for k = 1:size(spec, 1)
        defaults.(spec{k, 1}) = spec{k, 2};
    end
    [p, missing, unknown] = merge_inputs(defaults, params);

    out = sanitize(evaluate(antenna, p));

    info = struct('key', antenna, 'name', catalog{row, 2}, ...
                  'freq_range', catalog{row, 3}, 'defaults', defaults, ...
                  'params', p, 'missing', {missing}, 'unknown', {unknown});
end

% -------------------------------------------------------------------------
function o = evaluate(key, p)
%EVALUATE  One case per antenna; formulas mirror dashboard/app.js 1:1.
    c = 299.792458;   % speed of light [mm GHz]

    switch key
        case 'patch'
            erEff = (p.permittivity + 1) / 2 + ((p.permittivity - 1) / 2) * (1 + 12 * (p.height / p.width))^(-0.5);
            deltaL = 0.412 * p.height * ((erEff + 0.3) * (p.width / p.height + 0.264)) / ((erEff - 0.258) * (p.width / p.height + 0.8));
            Leff = p.length + 2 * deltaL;
            fr = c / (2 * Leff * sqrt(erEff));
            aspect = p.width / p.length;
            hLambda = (p.height / 1000) * (fr * 1e9 / 3e8);
            s11 = -24.5 + abs(aspect - 1.29) * 12.0 + abs(p.height - 1.6) * 4.0;
            s11 = min(-6.0, -abs(s11));
            gain = 6.2 + 10 * log10(aspect) * 0.4 - pick(p.permittivity > 4.5, 0.8, 0.0) + pick(p.height > 2.0, 0.3, 0.0);
            bw = (3.77 * ((p.permittivity - 1) / p.permittivity^2) * (p.height / (c / fr)) * aspect) * 1.8;
            o = struct('S11', s11, 'Gain', max(2.5, gain), 'BW', max(0.04, bw), 'Fr', fr, ...
                       'hLambda', hLambda, ...
                       'efficiency', max(65, 94 - (p.permittivity * 2.2) - pick(hLambda > 0.04, 12, 0)));

        case 'mimo'
            fr = 2.45 * (24.0 / p.length) * sqrt(4.4 / p.permittivity);
            s11 = -18.0 - (p.spacing / 20.0) * 4.0;
            isolation = -14.0 - (p.spacing * 0.65) - pick(p.spacing > 18, 4.0, 0.0);
            ecc = max(0.001, 0.05 * exp(-p.spacing / 8.0));
            o = struct('S11', s11, 'Isolation', isolation, 'ECC', ecc, ...
                       'Gain', 4.2 + pick(p.spacing > 15, 0.8, 0.2), ...
                       'BW', 0.22 + p.height * 0.05, 'Fr', fr, 'DG', 10 * sqrt(1 - ecc * ecc));

        case 'uwb'
            frLower = 3.1 * (12.0 / p.radius);
            o = struct('S11', -28.0 - (p.feedW - 2.8) * 3.5 + (p.groundGap - 0.5) * 4.0, ...
                       'Gain', 4.2 + (p.radius / 12.0) * 0.6, ...
                       'BW', 7.8 + (12.0 / p.radius) * 0.4 - (p.permittivity - 2.2) * 0.3, ...
                       'Fr', frLower, ...
                       'groupDelay', 0.82 + abs(p.groundGap - 0.5) * 0.2, ...
                       'notchFreq', 5.5 * (6.5 / p.notchL));

        case '5g'
            N = p.elements;
            o = struct('S11', -28.5 + abs(p.spacing - 5.36) * 14.0, ...
                       'Gain', 6.2 + 10 * log10(N) * 0.95 - (p.spacing - 5.36) * 1.5, ...
                       'BW', 2.2, 'Fr', 28.0, ...
                       'beamwidth', 90.0 / sqrt(N), ...
                       'sll', -13.2 - pick(p.spacing > 5.4, 1.5, 0.0));

        case 'fractal'
            f1 = 2.45 * (36.0 / p.baseL) * sqrt(4.4 / p.permittivity);
            f2 = pick(p.iter >= 1, 5.18 * (36.0 / p.baseL) * sqrt(4.4 / p.permittivity), 0);
            f3 = pick(p.iter >= 2, 8.45 * (36.0 / p.baseL) * sqrt(4.4 / p.permittivity), 0);
            o = struct('S11', -18.2 - (p.iter * 4.2), 'Gain', 5.2 - (p.iter * 0.35), ...
                       'BW', 0.18 + p.iter * 0.08, 'Fr', f1, 'f1', f1, 'f2', f2, 'f3', f3, ...
                       'sizeReduction', p.iter * 18.5);

        case 'horn'
            lambda = 30.0;
            gain = 10 * log10(4 * pi * (p.aFlare * p.bFlare * 0.51) / (lambda * lambda));
            s11 = -24.5 - (p.lHorn - 80) * 0.1;
            bwE = 51.0 * (lambda / p.aFlare);
            bwH = 70.0 * (lambda / p.bFlare);
            o = struct('S11', s11, 'Gain', max(12, gain), 'BW', 4.2, 'Fr', 10.0, ...
                       'beamwidthE', bwE, 'beamwidthH', bwH);

        case 'helical'
            C = pi * p.diameter;
            lambda0 = 125.0;
            gain = 10 * log10(6.2 * (C / lambda0)^2 * (p.turns * p.spacing / lambda0));
            ar = (2 * p.turns + 1) / (2 * p.turns);
            hpbw = 52.0 / ((C / lambda0) * sqrt(p.turns * p.spacing / lambda0));
            o = struct('S11', -19.5 - (p.turns - 6) * 0.4, 'Gain', max(8.0, gain), ...
                       'BW', 0.85, 'Fr', 2.4, 'axialRatio', ar, 'hpbw', hpbw);

        case 'dipole'
            fr = c / (2 * p.length * 1.05);
            s11 = -24.1 + abs(p.length - 58.0) * 0.8 + (p.feedGap - 2.0) * 1.5;
            bw = 0.22 * (p.radius / 0.8);
            o = struct('S11', min(-10, s11), 'Gain', 2.15, 'BW', bw, 'Fr', fr, 'Rin', 73.1);

        case 'yagi'
            gain = 7.5 + p.directors * 1.1 - abs(p.spacing - 22.0) * 0.15;
            fb = 14.0 + p.directors * 1.2;
            bw = 90.0 / sqrt(p.directors + 2);
            o = struct('S11', -18.4 - p.directors * 0.6, 'Gain', gain, 'BW', 0.25, 'Fr', 2.4, ...
                       'frontToBack', fb, 'beamwidth', bw);

        case 'dra'
            fr = (299.792458 / (2 * pi * p.radius * sqrt(p.permittivity + 2))) * (1.8 + 1.25 * (p.radius / p.height));
            s11 = -26.4 + abs(p.slotL - 6.0) * 6.0;
            bw = (0.06 * sqrt(p.permittivity) * (p.radius / p.height)) * 100;
            o = struct('S11', min(-12, s11), 'Gain', 5.8, 'BW', (bw / 100) * fr, 'Fr', fr, ...
                       'efficiency', 96.5);

        case 'bowtie'
            fr = 2.45 * (32.0 / p.armLen) * sqrt(4.4 / p.permittivity);
            bw = 2.4 * (p.flareW / 28.0);
            gain = 4.2 + (p.armLen / 32.0) * 0.5;
            o = struct('S11', -25.2 - (p.flareW - 28.0) * 0.4, 'Gain', gain, 'BW', bw, 'Fr', fr);

        case 'slot'
            fr = c / (2 * p.slotLen * sqrt((p.permittivity + 1) / 2));
            s11 = -22.0 + abs(p.feedOffset - 12) * 1.2;
            bw = 0.15 + (p.slotW / 4.0) * 0.1;
            o = struct('S11', min(-10, s11), 'Gain', 3.2 + (p.slotLen / 50) * 0.5, 'BW', bw, ...
                       'Fr', fr, 'Rin', 363);

        case 'logperiodic'
            gain = 6.5 + (p.nElements - 6) * 0.3 + (p.tau - 0.7) * 8;
            fr = 299.792458 / (2 * p.maxLen);
            bw = fr * (1 / p.tau^(p.nElements - 1) - 1);
            o = struct('S11', -18.0 - (p.sigma - 0.1) * 20, 'Gain', max(5, gain), ...
                       'BW', max(0.5, bw), 'Fr', fr);

        case 'vivaldi'
            fr = 3.0 * (55 / p.taperLen);
            gain = 7.5 + (p.aperture / 32) * 2 + (p.taperLen / 55) * 1.5;
            o = struct('S11', -22.0 - p.taperRate * 50, 'Gain', max(5, gain), ...
                       'BW', 14.0 * (p.taperLen / 55), 'Fr', fr);

        case 'parabolic'
            lambda = 25.0;   % 12 GHz
            effArea = 0.55 * pi * (p.diameter / 2)^2;
            gain = 10 * log10(4 * pi * effArea / (lambda * lambda));
            bw = 70 * lambda / p.diameter;
            o = struct('S11', -26.0, 'Gain', max(20, gain), 'BW', 3.0, 'Fr', 12.0, ...
                       'beamwidth', bw, 'efficiency', 55);

        case 'loop'
            R = p.circumference / (2 * pi);
            fr = c / p.circumference;
            s11 = -16.0 - (p.wireRadius - 1.0) * 4;
            gain = 1.76 + pick(p.circumference > 120, 2.5, 0) + p.nTurns * 0.5;
            o = struct('S11', min(-10, s11), 'Gain', gain, 'BW', 0.08 * fr, 'Fr', fr, ...
                       'Rrad', 31171 * (pi * R * R / (c / fr / 1000))^2);

        case 'monopole'
            fr = c / (4 * p.length);
            s11 = -20.0 + abs(p.length - 31) * 0.6;
            gain = 5.15 - pick(p.gpRadius < 50, 1.5, 0);
            o = struct('S11', min(-10, s11), 'Gain', gain, 'BW', 0.12 * fr * (p.radius / 0.6), ...
                       'Fr', fr, 'Rin', 36.5);

        case 'lens'
            lambda = 5.0;   % 60 GHz
            effArea = 0.60 * pi * (p.diameter / 2)^2;
            gain = 10 * log10(4 * pi * effArea / (lambda * lambda));
            o = struct('S11', -24.0, 'Gain', max(15, gain), 'BW', 8.0, 'Fr', 60.0, ...
                       'beamwidth', 70 * lambda / p.diameter);

        case 'ifa'
            totalLen = (p.length + p.height);
            erEff = (p.permittivity + 1) / 2;
            fr = (c / (4 * totalLen * sqrt(erEff))) * 1.05;
            matchErr = abs(p.feedOffset - 2.8) * 6.0;
            s11 = min(-6.0, -22.0 + matchErr);
            vswr = (1 + 10^(s11 / 20)) / (1 - 10^(s11 / 20));
            gain = 3.2 + (p.groundWidth / 40.0) * 0.6;
            bw = 0.24 * (p.height / 4.5);
            o = struct('S11', s11, 'VSWR', vswr, 'Gain', gain, 'Directivity', gain + 0.6, ...
                       'BW', bw, 'Fr', fr, 'efficiency', 86.0, 'hpbw', 84.0, 'fbRatio', 6.5, ...
                       'Rin', 50.0 + (p.feedOffset - 2.8) * 12.0, 'Xin', (p.length - 25.0) * 2.5);

        case 'cassegrain'
            cl = 0.3;   % m/ns
            lambda = cl / p.frequency;
            dishArea = pi * (p.dishDia / 2)^2;
            subBlockage = pi * (p.subDia / 2)^2;
            eff = 0.65 * (1 - subBlockage / dishArea);
            gain = 10 * log10(eff * 4 * pi * dishArea / (lambda * lambda));
            hpbw = 70.0 * (lambda / p.dishDia);
            s11 = -24.5 - pick(p.dishDia > 1.2, 3.0, 0.0);
            o = struct('S11', s11, 'VSWR', 1.13, 'Gain', gain, 'Directivity', gain + 0.8, ...
                       'BW', p.frequency * 0.18, 'Fr', p.frequency, 'efficiency', 68.0, ...
                       'hpbw', hpbw, 'fbRatio', 42.0, 'beamwidth', hpbw);

        case 'corrugatedhorn'
            lambda = c / p.frequency;
            effArea = 0.69 * pi * (p.apertureDia / 2)^2;
            gain = 10 * log10(4 * pi * effArea / (lambda * lambda));
            hpbw = 64.0 * (lambda / p.apertureDia);
            o = struct('S11', -28.5, 'VSWR', 1.08, 'Gain', gain, 'Directivity', gain + 0.4, ...
                       'BW', p.frequency * 0.32, 'Fr', p.frequency, 'efficiency', 94.0, ...
                       'hpbw', hpbw, 'fbRatio', 36.0, 'crossPol', -38.0);

        case 'biquad'
            fr = 2.45 * (30.5 / p.sideLen);
            optDist = 30.5 * 0.5;
            distErr = abs(p.reflDist - optDist);
            s11 = -24.0 + distErr * 2.5;
            gain = 11.2 + (p.reflWidth / 120.0) * 0.8 - distErr * 0.3;
            o = struct('S11', min(-8.0, s11), 'VSWR', 1.14, 'Gain', gain, 'Directivity', gain + 0.7, ...
                       'BW', 0.35, 'Fr', fr, 'efficiency', 91.0, 'hpbw', 48.0, 'fbRatio', 22.0, ...
                       'Rin', 50.0 + (p.reflDist - 15.0) * 4.0, 'Xin', (p.sideLen - 30.5) * 3.0);

        case 'spiral'
            fLow = c / (2 * pi * p.outerRadius);
            fHigh = c / (2 * pi * p.innerRadius);
            ar = 1.2 + pick(p.turns < 3.5, 0.6, 0.0);
            o = struct('S11', -18.5, 'VSWR', 1.27, 'Gain', 4.8 + (p.outerRadius / 45.0) * 0.5, ...
                       'Directivity', 5.5, 'BW', (fHigh - fLow), 'Fr', (fLow + fHigh) / 2, ...
                       'axialRatio', ar, 'efficiency', 62.0, 'hpbw', 72.0, 'fbRatio', 16.0);

        case 'discone'
            fMin = (c / (4 * p.coneLength));
            fMax = fMin * 8.5;
            o = struct('S11', -16.5, 'VSWR', 1.35, 'Gain', 2.8, 'Directivity', 3.2, ...
                       'BW', (fMax - fMin), 'Fr', fMin * 2.5, 'efficiency', 92.0, 'hpbw', 62.0, ...
                       'fbRatio', 0.0, 'Rin', 50.0 + (p.discGap - 6.0) * 3.0, 'Xin', 2.0);

        case 'turnstile'
            fr = (c / (2 * p.armLen * 0.96));
            s11 = -21.0 - pick(abs(p.reflDist - p.armLen / 2) < 10, 4.0, 0.0);
            o = struct('S11', s11, 'VSWR', 1.19, 'Gain', 6.8, 'Directivity', 7.4, ...
                       'BW', fr * 0.14, 'Fr', fr, 'axialRatio', 1.35, 'efficiency', 90.0, ...
                       'hpbw', 68.0, 'fbRatio', 18.0);

        case 'cornerreflector'
            fr = (c / (2 * p.dipoleLen * 0.95));
            gain = 12.8 + (90.0 / p.cornerAngle) * 0.8;
            s11 = -22.0 - pick(p.dipoleDist > 70, 3.0, 0.0);
            o = struct('S11', s11, 'VSWR', 1.17, 'Gain', gain, 'Directivity', gain + 0.6, ...
                       'BW', fr * 0.18, 'Fr', fr, 'efficiency', 94.0, 'hpbw', 38.0, 'fbRatio', 28.0);

        case 'patcharray'
            erEff = (p.permittivity + 1) / 2;
            fr = (c / (2 * p.patchL * sqrt(erEff))) * 0.95;
            elemGain = 6.2;
            arrayFactorGain = 10 * log10(16);
            feedLoss = 1.2;
            gain = elemGain + arrayFactorGain - feedLoss;
            o = struct('S11', -22.5, 'VSWR', 1.16, 'Gain', gain, 'Directivity', gain + 1.2, ...
                       'BW', 1.2, 'Fr', fr, 'efficiency', 78.0, 'hpbw', 18.5, 'fbRatio', 26.0, ...
                       'sll', -13.2);

        case 'collinear'
            fr = js_or(p.frequency, 0.915);
            gain = 2.15 + 10 * log10(p.numElems) * 0.85;
            elevHPBW = 78.0 / p.numElems;
            o = struct('S11', -19.5, 'VSWR', 1.23, 'Gain', gain, 'Directivity', gain + 0.5, ...
                       'BW', fr * 0.10, 'Fr', fr, 'efficiency', 92.0, 'hpbw', elevHPBW, ...
                       'fbRatio', 0.0, 'Rin', 50.0, 'Xin', 0.0);

        case 'ris'
            % (The dashboard engine fixes Fr at 28 GHz; the period does not enter.)
            totalCells = p.gridSize * p.gridSize;
            reflectGain = 10 * log10(totalCells) + 7.5;
            o = struct('S11', -22.0, 'VSWR', 1.17, 'Gain', reflectGain, ...
                       'Directivity', reflectGain + 1.0, 'BW', 3.5, 'Fr', 28.0, ...
                       'efficiency', 84.0, 'hpbw', 12.0, 'fbRatio', 24.0, ...
                       'phaseRange', ['340' char(176) ' Continuous'], 'loss', '0.8 dB');

        case 'whip'
            fr = js_or(p.frequency, 0.435);
            s11 = -17.5 - pick(p.turns > 20, 3.0, 0.0);
            o = struct('S11', s11, 'VSWR', 1.30, 'Gain', 1.8, 'Directivity', 2.2, ...
                       'BW', fr * 0.08, 'Fr', fr, 'efficiency', 72.0, 'hpbw', 78.0, ...
                       'fbRatio', 0.0, 'Rin', 48.0, 'Xin', 3.5);

        otherwise
            error('antenna_model:unknownAntenna', 'No engine for antenna type ''%s''.', key);
    end
end

% -------------------------------------------------------------------------
function catalog = antenna_catalog()
%ANTENNA_CATALOG  {key, full name, S11 chart range [GHz], {input, default; ...}}
%   Generated from dashboard/app.js (ANTENNA_CONFIGS).
    catalog = { ...
        'patch', 'Rectangular Microstrip Patch Antenna', [1.5 4], {'length', 29.4; 'width', 38; 'height', 1.6; 'permittivity', 4.4}; ...
        'mimo', '2-Port MIMO PIFA Antenna', [2 6], {'length', 24; 'width', 12; 'spacing', 20; 'height', 1.6; 'permittivity', 4.4}; ...
        'uwb', 'Ultra-Wideband Circular Monopole', [2.5 12], {'radius', 12; 'feedW', 2.8; 'groundGap', 0.5; 'notchL', 6.5; 'permittivity', 4.4}; ...
        '5g', '5G mmWave 28 GHz Phased Array', [24 32], {'elements', 16; 'spacing', 5.36; 'height', 0.254; 'permittivity', 2.2}; ...
        'fractal', 'Sierpinski Carpet Fractal Antenna', [1 11], {'baseL', 36; 'iter', 2; 'height', 1.6; 'permittivity', 4.4}; ...
        'horn', 'Pyramidal Horn Aperture Antenna', [8 12.5], {'aFlare', 68; 'bFlare', 52; 'lHorn', 80}; ...
        'helical', 'Axial-Mode Helical Antenna', [1.8 3.2], {'diameter', 39.8; 'spacing', 31.25; 'turns', 6}; ...
        'dipole', 'Resonant Half-Wave Dipole', [1.5 3.5], {'length', 58; 'radius', 0.8; 'feedGap', 2}; ...
        'yagi', 'Yagi-Uda Endfire Directive Array', [2 2.8], {'directors', 3; 'spacing', 22; 'refLen', 64}; ...
        'dra', 'Dielectric Resonator Antenna', [4.5 7.5], {'radius', 6.5; 'height', 7.2; 'permittivity', 10; 'slotL', 6}; ...
        'bowtie', 'Planar Bow-Tie Wideband Antenna', [1.5 5], {'armLen', 32; 'flareW', 28; 'feedGap', 1.5; 'permittivity', 4.4}; ...
        'slot', 'Rectangular Slot Antenna', [2 4], {'slotLen', 50; 'slotW', 4; 'feedOffset', 12; 'permittivity', 4.4}; ...
        'logperiodic', 'Log-Periodic Dipole Array (LPDA)', [0.5 3], {'tau', 0.86; 'sigma', 0.15; 'nElements', 10; 'maxLen', 240}; ...
        'vivaldi', 'Antipodal Vivaldi Tapered Slot Antenna', [2 18], {'taperLen', 55; 'aperture', 32; 'taperRate', 0.06; 'permittivity', 3.5}; ...
        'parabolic', 'Parabolic Reflector Dish Antenna', [10 14], {'diameter', 600; 'fOverD', 0.4; 'feedGain', 12}; ...
        'loop', 'Circular Loop Antenna', [0.5 2.5], {'circumference', 125; 'wireRadius', 1; 'nTurns', 1}; ...
        'monopole', 'Quarter-Wave Monopole Antenna', [0.8 3], {'length', 31; 'radius', 0.6; 'gpRadius', 60}; ...
        'lens', 'Dielectric Lens Antenna', [55 70], {'diameter', 30; 'thickness', 12; 'permittivity', 2.5}; ...
        'ifa', 'Inverted-F Antenna (IFA / PCB Trace)', [2 3], {'length', 25; 'height', 4.5; 'feedOffset', 2.8; 'groundWidth', 40; 'permittivity', 4.4}; ...
        'cassegrain', 'Cassegrain Dual-Reflector Antenna', [6 32], {'dishDia', 1.5; 'subDia', 0.18; 'focalRatio', 0.38; 'frequency', 12}; ...
        'corrugatedhorn', 'Corrugated Conical Horn Antenna', [8 40], {'apertureDia', 65; 'flareLength', 110; 'throatDia', 16; 'frequency', 18}; ...
        'biquad', 'Bi-Quad Double-Diamond Array Antenna', [2 6], {'sideLen', 30.5; 'reflDist', 15; 'reflWidth', 120; 'wireDia', 1.6}; ...
        'spiral', 'Archimedean Cavity-Backed Spiral Antenna', [2 18], {'outerRadius', 45; 'innerRadius', 2.2; 'turns', 4; 'cavityDepth', 20}; ...
        'discone', 'Broadband Discone Omnidirectional Antenna', [0.1 1.5], {'discRadius', 90; 'coneLength', 220; 'coneAngle', 30; 'discGap', 6}; ...
        'turnstile', 'Turnstile Crossed-Dipole Space Antenna', [0.1 1.2], {'armLen', 260; 'reflDist', 130; 'wireRadius', 3; 'frequency', 0.435}; ...
        'cornerreflector', ['90' char(176) ' Corner Reflector Directive Antenna'], [0.4 2.5], {'dipoleDist', 75; 'cornerAngle', 90; 'plateLen', 200; 'dipoleLen', 125}; ...
        'patcharray', ['4' char(215) '4 Corporate-Fed Patch Array'], [22 32], {'patchL', 3.2; 'patchW', 4.1; 'spacing', 6; 'permittivity', 2.2}; ...
        'collinear', 'High-Gain Collinear Phased Dipole Array', [0.15 2.7], {'numElems', 4; 'elemLen', 145; 'coilDist', 25; 'frequency', 0.915}; ...
        'ris', 'Reconfigurable Intelligent Surface (RIS / 6G Metasurface)', [24 38], {'gridSize', 12; 'period', 3.5; 'patchGap', 0.4; 'permittivity', 3.55}; ...
        'whip', 'Helical Whip / Rubber Ducky Handheld Antenna', [0.13 0.95], {'coilLen', 110; 'coilDia', 9; 'turns', 26; 'frequency', 0.435} ...
    };
end

% -------------------------------------------------------------------------
function [p, missing, unknown] = merge_inputs(defaults, params)
%MERGE_INPUTS  Overlay supplied inputs on the defaults (numbers only).
    p = defaults;
    names = fieldnames(defaults);
    missing = {};
    unknown = {};
    if ~isstruct(params) || ~isscalar(params)
        params = struct();
    end
    for k = 1:numel(names)
        nm = names{k};
        v = [];
        if isfield(params, nm)
            v = params.(nm);
        end
        if ischar(v) || isstring(v)
            v = str2double(v);
        end
        if (isnumeric(v) || islogical(v)) && ~isempty(v)
            p.(nm) = double(v(1));
        else
            missing{end + 1} = nm; %#ok<AGROW>
        end
    end
    given = fieldnames(params);
    for k = 1:numel(given)
        if ~any(strcmp(given{k}, names))
            unknown{end + 1} = given{k}; %#ok<AGROW>
        end
    end
end

function v = pick(cond, a, b)
%PICK  Scalar "cond ? a : b", as written in the JavaScript engine.
    if cond
        v = a;
    else
        v = b;
    end
end

function v = js_or(x, fallback)
%JS_OR  JavaScript "x || fallback": 0 and NaN fall back.
    if isempty(x) || isnan(x) || x == 0
        v = fallback;
    else
        v = x;
    end
end

function o = sanitize(o)
%SANITIZE  Complex or non-finite numeric outputs become NaN (JSON null).
    names = fieldnames(o);
    for k = 1:numel(names)
        v = o.(names{k});
        if isnumeric(v) && (~isreal(v) || any(~isfinite(v(:))))
            o.(names{k}) = NaN;
        end
    end
end
