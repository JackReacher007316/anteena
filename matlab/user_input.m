%% ============================================================
%  user_input.m
%  Opens the interactive visual GUI Workstation with sliders & live plots
% ============================================================

function varargout = user_input(varargin)
% USER_INPUT Launches the interactive visual antenna design workstation
% with input sliders, CST connection, and real-time verification curves.
%
% USAGE:
%   user_input
%   antenna_gui

    if nargout > 0
        [varargout{1:nargout}] = antenna_gui();
    else
        antenna_gui();
    end
end
