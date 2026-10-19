%% ============================================================
%  verify_antenna.m
%  Convenience alias for cst_matlab_verify
% ============================================================

function varargout = verify_antenna(varargin)
% VERIFY_ANTENNA Verification command for CST Studio Suite & ML Surrogate Models
%
% USAGE:
%   verify_antenna
%   verify_antenna('patch')
%   verify_antenna('patch', 'gpr')
%   verify_antenna('mimo',  'svm')
%   verify_antenna('uwb',   'ann')

    if nargout > 0
        [varargout{1:nargout}] = cst_matlab_verify(varargin{:});
    else
        cst_matlab_verify(varargin{:});
    end
end
