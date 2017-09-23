%%%---------------------------------------------------------------------------
%%% @doc
%%%   Subprocess ports with read backpressure and unix OS operations.
%%%
%%%   This module provides Erlang ports with read backpressure (for instance,
%%%   spawning `yes(1)' won't cause out of memory) and some useful options
%%%   available on unix operating systems, like spawning subprocesses with
%%%   STDIO redirected with `socketpair(2)', spawning them in process groups,
%%%   and sending them signals.
%%%
%%% @see subproc_unix
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc).

-export([exec/3, open/2, close/1]).
-export([close/2, signal/1, signal/2]).
-export([send/2, recv/2, recv/3]).
-export([setopts/2, getopts/2, controlling_process/2]).
-export([config_reload/0]).
-export([format_error/1]).

-export_type([handle/0, stdio/0]).
-export_type([exec_option/0, port_option/0, read_option/0, native_read_option/0]).
-export_type([message/0]).
-export_type([posix/0]).
-export_type([os_pid/0, os_fd/0, uid/0, gid/0]).
-export_type([exit_code/0, signal/0, signal_name/0, signal_number/0]).

%%%---------------------------------------------------------------------------
%%% types {{{

-type handle() :: port().
%% Port associated with an OS subprocess spawned by this module.

-type stdio() :: {bidir, FDRW :: os_fd()}
               | {in, FDR :: os_fd()}
               | {out, FDW :: os_fd()}
               | {in_out, {FDR :: os_fd(), FDW :: os_fd()}}.
%% File descriptors for reading and/or writing from/to subprocess.
%% `FDR' is for reading, `FDW' is for writing, and `FDRW' is for both reading
%% and writing (bidirectional communication).

-type exec_option() :: {stdio, bidir | in | out | in_out}
                     | {type, socket | pipe}
                     | stderr_to_stdout
                     | pgroup
                     | term_pgroup
                     | {termsig, signal() | close}
                     | {ignore_signals, [signal()]}
                     | {nice, integer()}
                     | {user, uid() | string()}
                     | {group, gid() | string()}
                     | {cd, file:filename()}
                     | {argv0, file:filename()}.
%% Options controlling how the subprocess is executed.
%%
%% <ul>
%%   <li>`{stdio,_}' -- specifies what part of STDIO is redirected: `in' reads
%%       data into Erlang from process' STDIN, `out' writes data from Erlang
%%       to process' STDIN, `in_out' does both, and `bidir' does both on the
%%       same descriptor (`bidir' is only supported with `{type,socket}')</li>
%%   <li>`{type,_}' -- type of file descriptor to use: `socket' uses
%%       `socketpair(2)', `pipe' uses `pipe(2)'</li>
%%   <li>`stderr_to_stdout' -- when set, STDERR is redirected to the same
%%       descriptor as STDOUT</li>
%%   <li>`pgroup' -- when set, the subprocess is spawned in its own process
%%       group (its children inherit the process group), so signals,
%%       including `termsig', are sent to the whole group instead of just the
%%       subprocess</li>
%%   <li>`term_pgroup' -- when set along with `pgroup', `termsig' is sent to
%%       the whole process group when the subprocess (group leader)
%%       terminates</li>
%%   <li>{@type @{termsig, signal() | close@}} -- termination signal, sent on
%%       {@link close/1}, {@link signal/1}, on port termination, and on
%%       `subproc' application shutdown; when set to `close', the subprocess
%%       is supposed to exit when its STDIO is closed and thus no signal is
%%       sent</li>
%%   <li>`{ignore_signals,_}' -- list of signals to ignore in the
%%       subprocess</li>
%%   <li>`{nice,_}' -- change in subprocess' priority (`setpriority(2)'); note
%%       that some values may require special privileges (usually root
%%       rights)</li>
%%   <li>`{user,_}', `{group,_}' -- change in UID and GID under which the
%%       subprocess will be running; note that these options usually require
%%       root rights</li>
%%   <li>`{cd,_}' -- when set, the subprocess will be spawned in specified
%%       directory</li>
%%   <li>`{argv0,_}' -- when set, process name (sometimes called `argv[0]' or
%%       `$0') will be set to this value</li>
%% </ul>
%%
%% <b>NOTE</b>: If `{type,socket}' is specified, the socket descriptor(s) will
%% be created with `AF_UNIX' domain and `SOCK_STREAM' type and partially
%% closed (`shutdown(2)') to fit the requested read/write mode. With
%% `{stdio,bidir}', the descriptor is duplicated to both STDIN and STDOUT of
%% the child process.

-type native_read_option() :: term().
%% Options controlling native port's behaviour. See {@link erlang:open_port/2}
%% documentation for supported options. These options replace
%% {@type read_option()} options when a native port is requested.

-type port_option() :: subproc | native | raw_fd
                     | {close, boolean()}
                     | {close_on_exit, boolean()}.
%% Options controlling port's external behaviour (API).
%%
%% <ul>
%%   <li>`subproc' -- spawn a `subproc'-type port; use functions from this
%%       module to interact with such port</li>
%%   <li>`native' -- spawn a port using Erlang's built-in mechanisms (namely,
%%       {@link erlang:open_port/2});  use {@link erlang:port_command/2},
%%       {@link erlang:port_connect/2}, and {@link erlang:port_close/1} to
%%       interact with such port</li>
%%   <li>`raw_fd' -- don't spawn a port, return raw file descriptors
%%       ({@type stdio()}) and PID ({@type os_pid()}) instead</li>
%%   <li>`{close,_}' -- when set to `true', subprocess' file descriptors will
%%       be closed on port termination (applies to both `subproc' and `native'
%%       ports); this flag is intended to replicate Erlang's behaviour of not
%%       closing the descriptors for ports spawned from `{fd,FDR,FDW}'</li>
%%   <li>`{close_on_exit,_}' -- when set to `true', the subprocess' STDIN and
%%       STDOUT will be closed when subprocess terminates on exit or signal
%%       (applies only to `subproc' ports)</li>
%% </ul>
%%
%% <b>NOTE</b>: `native'-type port requires {@type exec_option()} `{stdio,
%% in_out}'.
%%
%% <b>NOTE</b>: With `close_on_exit' set to `true', any output produced by
%% subprocess' children after subprocess' termination will be discarded,
%% though it's a safe setting for the subprocess' own output.

-type read_option() :: list | binary | {mode, list | binary}
                     | {active, true | false | once}
                     | {packet, 0 | 1 | 2 | 4 | raw | line}
                     | {packet_size, pos_integer()}.
%% Options controlling how data from `subproc' type ports is read.
%%
%% <ul>
%%   <li>`list', `binary', `{mode,_}' -- data is returned as {@type string()}
%%       or as {@link binary()} (for {@type @{packet, 1 | 2 | 4@}}, `binary'
%%       mode should be a little faster)</li>
%%   <li>`{active,_}' -- set receiving {@type message()} messages from port;
%%       when set to `false', the port will not send any data on its own and
%%       {@link recv/2} or {@link recv/3} call is required</li>
%%   <li>`{packet,_}' -- packet format to read from the port; `{packet, 0}'
%%       and `{packet, raw}' are synonymous, with the latter being the
%%       canonical form ({@link getopts/2})</li>
%%   <li>`{packet_size,_}' -- maximum allowed size of a single packet; if
%%       a packet read exceeds this size, read returns an error and
%%       subprocess' STDOUT is closed; maximum supported size is 67108864 (64
%%       MB)</li>
%% </ul>

-type message() :: {subproc, Port :: handle(), Data :: binary() | string()}
                 | {subproc_closed, Port :: handle()}
                 | {subproc_error, Port :: handle(), Reason :: term()}
                 | {subproc_exit, Port :: handle(), exit_code()}
                 | {subproc_signal, Port :: handle(),
                     {signal_number(), signal_name()}}.
%% Messages sent in `{active,true}' and `{active,once}' modes.
%%
%% <ul>
%%   <li>`subproc' -- regular payload</li>
%%   <li>`subproc_error' -- read error, after which read descriptor is
%%       closed</li>
%%   <li>`subproc_closed' -- EOF on subprocess' STDOUT (read end of this
%%       descriptor is closed)</li>
%%   <li>`subproc_exit', `subproc_signal' -- subprocess terminated calling
%%       `exit(2)' or on signal, accordingly</li>
%% </ul>
%%
%% If {@type port_option()} `{close_on_exit,true}' was set,
%% `subproc_exit'/`subproc_signal' message will be delayed until all remaining
%% output data is read, so termination info will be the last message. With
%% `{close_on_exit,false}', child processes can still produce and receive
%% data after termination info is received.
%%
%% If the port was opened with {@link open/2} function, the last message will
%% be `subproc_closed' or `subproc_error'.
%%
%% Most notable errors:
%% <ul>
%%   <li>`{error,closed}' -- last message before EOF was incomplete</li>
%%   <li>`{error,emsgsize}' -- message was larger than `packet_size'
%%       {@type read_option()}</li>
%% </ul>

-type posix() :: inet:posix().
%% Atom representation of an `errno' value.

-type os_pid() :: pos_integer().
%% PID of an OS-level process.

-type os_fd() :: non_neg_integer().
%% File descriptor, usable for `read(2)', `write(2)', and `close(2)'.

-type uid() :: 0 .. 65535.
%% UID number of a process.

-type gid() :: 0 .. 65535.
%% GID number of a process.

-type exit_code() :: 0 .. 255.
%% Exit code of a process.

-type signal() :: signal_number() | signal_name().
%% Signal representation. Both signal names (`term', `hup', `kill') and signal
%% numbers (15, 1, 9) are supported, but signal names are preferred (some
%% signals can have different values under different OS-es, most notably,
%% `usr1' `usr2', `stop', and `cont').

-type signal_number() :: 1 .. 31.
%% Integer value of a signal. Different OS-es can assign different meaning to
%% each number; {@type signal_name()} is a more portable alternative.

-type signal_name() :: hup | int | quit | kill | term | usr1 | usr2
                     | abrt | alrm | stop | cont | atom().
%% Symbolic name of a signal. Lower case with `"SIG"' prefix stripped.

%%% }}}
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% start/stop subprocess {{{

%% @doc Execute a subprocess, redirecting its STDIN and/or STDOUT.
%%
%%   Result is a `subproc' port, which can be operated on with all the other
%%   functions in this module.
%%
%%   Caller can request spawning a port of Erlang's built-in type by using
%%   option `native' (options `noclose' and `noclose_on_exit' are still
%%   valid). In such case {@type read_option()} options should be replaced
%%   with {@type native_read_option()} options.
%%
%%   Caller can also request raw file descriptors, without spawning any port
%%   (option `raw_fd'). The caller is then responsible for closing the
%%   descriptors once they aren't needed (e.g. with
%%   {@link subproc_unix:close/1}).
%%
%%   Default options for `subproc' port are: `subproc', `{close,true}',
%%   `{close_on_exit,true}', `{stdio,in_out}', `{type,pipe}',
%%   `{termsig,close}', `{ignore_signals,[]}', `{active,false}',
%%   `{mode,list}', `{packet,raw}', `{packet_size,16384}'.
%%
%%   When `{type,socket}' is specified without accompanying `{stdio,_}'
%%   option, `{stdio,bidir}' {@type exec_option()} is set as the default.
%%
%% @see open/2

-spec exec(file:filename(), [string()], Options :: [Option]) ->
    {ok, handle() | port() | RawInfo}
  | {error, badarg | system_limit | ExecError | RequestError}
  when Option :: exec_option() | port_option() | read_option()
               | native_read_option(),
       RawInfo :: {ID :: pos_integer(), PID :: os_pid(), FDs :: stdio()},
       ExecError :: {Stage :: atom(), Error :: posix()},
       % mainly: nxuser, nxgroup, bad_signal, stdio_pipe_bidir,
       % request_too_big, no_child_space (plus internal errors catch-all)
       RequestError :: atom().

exec(Command, Args, Options) ->
  subproc_master:exec(Command, Args, Options).

%% @doc Open a port from raw file descriptors, without executing a subprocess.
%%
%%   This function is mainly intended for creating a `subproc' port for
%%   already opened descriptors, so they can be read with proper backpressure
%%   (usually for `{in, 0}' for Erlang's STDIN). `native'-type port can also
%%   be spawned with {@link erlang:open_port/2}, but this function allows to
%%   use the `{close,true}' flag. `raw_fd' is only included for completeness,
%%   as it's essentially a no-op.
%%
%%   Since there's no known subprocess behind these descriptors,
%%   `{close_on_exit,_}' option is ignored.
%%
%%   Default options for `subproc' port are: `subproc', `{close,true}',
%%   `{active,false}', `{mode,list}', `{packet,raw}', `{packet_size,16384}'.
%%
%%   In case of an error, the caller is responsible for closing the
%%   descriptors.
%%
%% @see exec/3

-spec open(stdio(), Options :: [Option]) ->
  {ok, handle() | port() | stdio()} | {error, badarg | system_limit}
  when Option :: port_option() | read_option() | native_read_option().

open(STDIO, Options) ->
  subproc_master:open(STDIO, Options).

%% @doc Send a termination signal to the subprocess and close the associated
%%   port.
%%
%%   The function <i>does not</i> wait for the subprocess to terminate. To
%%   achieve this, use {@link signal/1} or {@link close/2} (depending on
%%   subprocess' behaviour) and wait for termination message either in active
%%   mode or by repeatedly calling {@link recv/2} or {@link recv/3}.

-spec close(handle()) ->
  ok.

close(Port) ->
  signal(Port, default),
  subproc_worker_driver:close(Port).

%% }}}
%%----------------------------------------------------------
%% partial shutdown {{{

%% @doc Close subprocess' file descriptor(s) without killing the subprocess.

-spec close(handle(), read | write | read_write) ->
  ok | {error, badarg}.

close(Port, How) ->
  subproc_worker_driver:close(Port, How).

%% @doc Send to the subprocess its default termination signal.

-spec signal(handle()) ->
  ok | {error, closed | badarg | posix()}.

signal(Port) ->
  signal(Port, default).

%% @doc Send to the subprocess a specific signal.
%%
%%   If the subprocess already terminated or the port was not spawned with
%%   {@link exec/3} or {@link open/2}, `{error, badarg}' is returned.

-spec signal(handle(), signal() | default) ->
  ok | {error, badarg | bad_signal | posix()}.

signal(Port, Signal) ->
  subproc_master:kill(Port, Signal).

%% }}}
%%----------------------------------------------------------
%% send/receive data {{{

%% @doc Send data to the subprocess.

-spec send(handle(), iolist()) ->
  ok | {error, closed | posix()}.

send(Port, Data) ->
  subproc_worker_driver:send(Port, Data).

%% @doc Read data from the subprocess.
%%
%%   Equivalent to `recv(Port, Length, infinity)', except that this call never
%%   returns `{error,timeout}'.
%%
%% @see recv/3

-spec recv(handle(), non_neg_integer()) ->
    {ok, Data :: string() | binary()}
  | eof
  | {terminated, Exit | Signal}
  | {error, closed | posix()}
  when Exit :: {exit, exit_code()},
       Signal :: {signal, signal_number(), signal_name()}.

recv(Port, Length) ->
  subproc_worker_driver:recv(Port, Length, infinity).

%% @doc Read data from the subprocess.
%%
%%   If {@type port_option()} `{close_on_exit,true}' was set, `{terminated,_}'
%%   will be returned after all remaining output data is read, so termination
%%   info will be the last returned value. With `{close_on_exit,false}', child
%%   processes can still produce and receive data after termination info is
%%   returned.
%%
%%   If the port was opened with {@link open/2} function, the last returned
%%   value will be `eof' or `{error,_}'.
%%
%%   Most notable errors:
%%   <ul>
%%     <li>`{error,timeout}' -- nothing to read before timeout expired (read
%%         descriptor stays open)</li>
%%     <li>`{error,eintr}' -- `recv()' call was interrupted by changing read
%%         mode to active (read descriptor stays open)</li>
%%     <li>`{error,einval}' -- port is in active mode or non-zero length
%%         specified for non-raw packet (read descriptor stays open)</li>
%%     <li>`{error,ealready}' -- another `recv()' is already in progress (read
%%         descriptor stays open)</li>
%%     <li>`{error,closed}' -- last message before EOF was incomplete, read
%%         descriptor was closed during `recv()', or read descriptor was
%%         already closed</li>
%%     <li>`{error,emsgsize}' -- message was larger than `packet_size'
%%         {@type read_option()}</li>
%%   </ul>
%%
%%   Except when noted above, read errors and `eof' cause read descriptor to
%%   be closed.

-spec recv(handle(), non_neg_integer(), timeout()) ->
    {ok, Data :: string() | binary()}
  | eof
  | {terminated, Exit | Signal}
  | {error, closed | timeout | posix()}
  when Exit :: {exit, exit_code()},
       Signal :: {signal, signal_number(), signal_name()}.

recv(Port, Length, Timeout) ->
  subproc_worker_driver:recv(Port, Length, Timeout).

%% }}}
%%----------------------------------------------------------
%% port administrative operations {{{

%% @doc Set one or more port options.
%%
%%   See {@type message()} for messages in `{active,true}' and `{active,once}'
%%   modes.
%%
%% @todo Allow `{close,_}' and `{close_on_exit,_}' options

-spec setopts(handle(), Options :: [Option]) ->
  ok | {error, badarg}
  when Option :: {close, boolean()}
               | {close_on_exit, boolean()}
               | read_option().

setopts(Port, Options) ->
  case subproc_worker_driver:setopts(Port, Options) of
    ok -> ok; % TODO: set `{close,_}' and `{close_on_exit,_}' options
    {error, Reason} -> {error, Reason}
  end.

%% @doc Read one or more port options.

-spec getopts(handle(), Options :: [OptionName]) ->
  {ok, [Option]} | {error, badarg}
  when OptionName :: mode | active | packet | packet_size
                   | pid | close | close_on_exit,
       Option :: read_option()
               | {pid, PID} | {close, boolean()} | {close_on_exit, boolean()},
       PID :: os_pid() | undefined.

getopts(Port, Options) ->
  case subproc_worker_driver:getopts(Port, Options) of
    {ok, Values} -> {ok, Values}; % TODO: read `close' and `close_on_exit'
    {error, Reason} -> {error, Reason}
  end.

%% @doc Assign a new owner to a port.

-spec controlling_process(handle(), pid()) ->
  ok | {error, not_owner | closed | badarg}.

controlling_process(Port, Pid) ->
  subproc_worker_driver:controlling_process(Port, Pid).

%% }}}
%%----------------------------------------------------------
%% reload application's environment {{{

%% @doc Reload application's environment (shutdown options).
%%
%% @todo Report config errors.

-spec config_reload() ->
  ok.

config_reload() ->
  subproc_master:reload().

%% }}}
%%----------------------------------------------------------
%% format error {{{

%% @doc Format a reason from error tuple as a usable error message.

-spec format_error(Reason :: term()) ->
  string().

%% general errors (`send()', `recv()', `signal()', `setopts()', `getopts()',
%% `controlling_process()')
format_error(badarg) ->
  "bad argument";
format_error(closed) ->
  "file descriptor closed";
format_error(timeout) ->
  "operation timed out";
format_error(not_owner) ->
  "not the owner of the port";

%% port spawning error (`open()', `exec()')
format_error(system_limit) ->
  "too many spawned ports";

%% errors from `exec()' (NOTE: OS errors from `send()', `recv()', `signal()'
%% can be safely handled by `subproc_master:format_error()')
format_error(RequestError) when is_atom(RequestError) ->
  subproc_master:format_error(RequestError);
format_error({_Stage, _Posix} = ExecError) ->
  subproc_master:format_error(ExecError);

%% unrecognized
format_error(_Reason) ->
  "unrecognized error".

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
