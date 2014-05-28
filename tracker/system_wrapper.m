function [trajectory, time] = system_wrapper(tracker, sequence, context, varargin)
% SYSTEM_WRAPPER  A wrapper around external system command that handles 
% reinicialization when the tracker fails.
%
%   [TRAJECTORY, TIME] = SYSTEM_WRAPPER(TRACKER, SEQUENCE, CONTEXT)
%              Runs the tracker on a sequence. The resulting trajectory is
%              a composite of all correctly tracked fragments. Where
%              reinitialization occured, the frame is marked using a
%              special notation.
%
%   See also RUN_TRACKER.

skip_labels = {};

skip_initialize = 1;

fail_overlap = -1; % disable failure detection by default

args = varargin;
for j=1:2:length(args)
    switch varargin{j}
        case 'skip_labels', skip_labels = args{j+1};
        case 'skip_initialize', skip_initialize = max(1, args{j+1}); 
        case 'fail_overlap', fail_overlap = args{j+1};            
        otherwise, error(['unrecognized argument ' args{j}]);
    end
end

start = 1;

total_time = 0;
total_frames = 0;

trajectory = cell(sequence.length, 1);

trajectory(:) = {0};

while start < sequence.length

    [Tr, Tm] = run_once(tracker, sequence, start, context);

    % in case when we only want to know runtime command for testing
    if isfield(context, 'fake') && context.fake
        trajectory = Tr;
        time = Tm;
        return;
    end
    
    if isempty(Tr)
        trajectory = [];
        time = NaN;
        return;
    end;

    total_time = total_time + Tm * size(Tr, 1);
    total_frames = total_frames + size(Tr, 1);

    overlap = calculate_overlap(Tr, get_region(sequence, start:sequence.length));

    failures = find(overlap' <= fail_overlap | ~isfinite(overlap'));
    failures = failures(failures > 1);

    trajectory(start) = {1};
        
    if ~isempty(failures)

        first_failure = failures(1) + start - 1;
        
        trajectory(start + 1:min(first_failure, size(Tr, 1) + start - 1)) = ...
            Tr(2:min(first_failure - start + 1, size(Tr, 1)));

        trajectory(first_failure) = {2};
        start = first_failure + skip_initialize;
                
        print_debug('INFO: Detected failure at frame %d.', first_failure);
        
        if ~isempty(skip_labels)
            for i = start:sequence.length
                if isempty(intersect(get_labels(sequence, i), skip_labels))
                    start = i;
                    break;
                end;                
            end;
        end;

        print_debug('INFO: Reinitializing at frame %d.', start);
    else
        
        if size(Tr, 1) > 1
            trajectory(start + 1:min(sequence.length, size(Tr, 1) + start - 1)) = ...
                Tr(2:min(sequence.length - start + 1, size(Tr, 1)));
        end;
        
        start = sequence.length;
    end;

    drawnow;
    
end;

time = total_time / total_frames;

end

function [trajectory, time] = run_once(tracker, sequence, start, context)
% RUN_TRACKER  Generates input data for the tracker, runs the tracker and
% validates results.
%
%   [TRAJECTORY, TIME] = RUN_TRACKER(TRACKER, SEQUENCE, START, CONTEXT)
%              Runs the tracker on a sequence that with a specified offset.
%
%   See also RUN_TRIAL, SYSTEM.

% create temporary directory and generate input data

if isempty(tracker.command)
    error('Unable to execute tracker %s. No command given.', tracker.identifier);
end;

working_directory = prepare_trial_data(sequence, start, context);

output_file = fullfile(working_directory, 'output.txt');

library_path = '';

output = [];

% in case when we only want to know runtime command for testing
if isfield(context, 'fake') && context.fake
    trajectory = tracker.command;
    time = working_directory;
    return;
end

if ispc
    library_var = 'PATH';
else
    library_var = 'LD_LIBRARY_PATH';
end;

% run the tracker
old_directory = pwd;
try

    print_debug(['INFO: Executing "', tracker.command, '" in "', working_directory, '".']);

    cd(working_directory);

    if is_octave()
        tic;
        [status, output] = system(tracker.command, 1);
        time = toc;
    else

		% Save library paths
		library_path = getenv(library_var);

        % Make Matlab use system libraries
        if ~isempty(tracker.linkpath)
            userpath = tracker.linkpath{end};
            if length(tracker.linkpath) > 1
                userpath = [sprintf(['%s', pathsep], tracker.linkpath{1:end-1}), userpath];
            end;
            setenv(library_var, [userpath, pathsep, getenv('PATH')]);
        else
		    setenv(library_var, getenv('PATH'));
        end;

		if verLessThan('matlab', '7.14.0')
		    tic;
		    [status, output] = system(tracker.command);
		    time = toc;
		else
		    tic;
		    [status, output] = system(tracker.command, '');
		    time = toc;
		end;
    end;
        
    if status ~= 0 
        print_debug('WARNING: System command has not exited normally.');
    end;

catch e

	% Reassign old library paths if necessary
	if ~isempty(library_path)
		setenv(library_var, library_path);
	end;

    print_debug('ERROR: Exception thrown "%s".', e.message);
end;

cd(old_directory);

% validate and process results
trajectory = read_trajectory(output_file);

n_frames = size(trajectory, 1);

time = time / (sequence.length-start);

if (n_frames ~= (sequence.length-start) + 1)
    print_debug('WARNING: Tracker did not produce a valid trajectory file.');
    
    if ~isempty(output)
        print_text('Printing command line output:');
        print_text('-------------------- Begin raw output ------------------------');
        % This prevents printing of backspaces and such
        disp(output(output > 31 | output == 10 | output == 13));
        print_text('--------------------- End raw output -------------------------');
    end;
    
    if isempty(trajectory)
        error('No result produced by tracker. Stopping.');
    else
        error('The number of frames is not the same as in groundtruth. Stopping.');
    end;
end;

if get_global_variable('cleanup', 1)
    % clean-up temporary directory
    recursive_rmdir(working_directory);
end;

end

