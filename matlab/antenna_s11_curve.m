function [f, s11] = antenna_s11_curve(antenna, out, freq_range, npts)
%ANTENNA_S11_CURVE  Noise-free S11 trace drawn by the web dashboard.
%
%   [f, s11] = antenna_s11_curve(antenna, out)
%   [f, s11] = antenna_s11_curve(antenna, out, freq_range, npts)
%
%   Returns the S11 response [dB] on NPTS points (default 200) across
%   FREQ_RANGE [GHz] (default: the antenna's chart range) for the engine
%   outputs OUT (see ANTENNA_MODEL): a resonance at out.Fr with depth
%   out.S11 and a width set by out.BW. Fractal antennas add their higher
%   bands out.f2 and out.f3. Values are clipped to [-45, -1] dB, exactly
%   like the dashboard chart (dashboard/app.js, generateS11Curve without
%   the display noise). F and S11 are column vectors.
%
%   Example
%       [o, info] = antenna_model('patch');
%       [f, s] = antenna_s11_curve('patch', o, info.freq_range);
%       plot(f, s), grid on, xlabel('Frequency (GHz)'), ylabel('S_{11} (dB)')
%
%   See also ANTENNA_MODEL, VERIFY_WEB_INPUT, LIVE_VERIFY.

    if nargin < 3 || isempty(freq_range)
        [~, info] = antenna_model(antenna);
        freq_range = info.freq_range;
    end
    if nargin < 4 || isempty(npts)
        npts = 200;
    end

    i = 0:(npts - 1);
    f = freq_range(1) + (freq_range(2) - freq_range(1)) * (i / (npts - 1));
    df = (f - out.Fr) / (out.BW * 0.35 + 0.01);
    s11 = out.S11 * exp(-0.28 * df .* df);

    % Multi-band dips of the Sierpinski fractal.
    if strcmpi(antenna, 'fractal')
        if isfield(out, 'f2') && out.f2 > 0
            df2 = (f - out.f2) / 0.12;
            s11 = s11 + -18.0 * exp(-0.35 * df2 .* df2);
        end
        if isfield(out, 'f3') && out.f3 > 0
            df3 = (f - out.f3) / 0.18;
            s11 = s11 + -15.0 * exp(-0.35 * df3 .* df3);
        end
    end

    s11 = max(-45, min(-1, s11));
    f = f(:);
    s11 = s11(:);
end
