%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Functions for working with master port driver directly.
%%%
%%% @see subproc_master
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_master_driver).

%% public interface
-export([open/1, pidof/1, close/1]).
-export([exec/4, kill/2, kill/3, shutdown_options/3, shutdown/1, shutdown/3]).
-export([decode_event/1]).
-export([format_error/1]).
%% function for `subproc_master'
-export([is_option/1, stdio_mode/1]).

-export_type([handle/0]).
-export_type([user/0, group/0, uid/0, gid/0]).
-export_type([subproc_id/0, posix/0, event_message/0]).

%%%---------------------------------------------------------------------------
%%% types

%% for port driver
-define(DRIVER_SUP_EXE_NAME, "subproc_unix_supervisor").
-define(DRIVER_SUP_NAME, "subproc_sup_drv").

-type handle() :: port().

-type user() :: string().
-type group() :: string().

-type uid() :: 0 .. 65535.
-type gid() :: 0 .. 65535.

-type subproc_id() :: pos_integer().
-type posix() :: inet:posix().

-type event_message() :: {subproc_sup, handle(), EventData :: binary(),
                           FDs :: [subproc_unix:os_fd(), ...]}.

-type request() :: binary() | iolist().

%%%---------------------------------------------------------------------------
%%% definitions for protocol

%%----------------------------------------------------------
%% request messages {{{

%% request types (8 bits)
-define(TAG_REQ_EXEC, 16#01).
-define(TAG_REQ_KILL, 16#02).
-define(TAG_REQ_SHUT_OPTS, 16#fe).
-define(TAG_REQ_SHUTDOWN,  16#ff).

%% reply tags (16 bits)
-define(TAG_ACK_OK,         16#0100).
-define(TAG_ACK_REQ_ERROR,  16#0201).
-define(TAG_ACK_OS_ERROR,   16#0202).

%% "execute" command flags
-define(STDIO_BIDIR,  16#00). % event will carry one FD: [FDRW]
-define(STDIO_IN,     16#01). % event will carry one FD: [FDW]
-define(STDIO_OUT,    16#02). % event will carry one FD: [FDR]
-define(STDIO_IN_OUT, 16#03). % event will carry two FDs: [FDW, FDR]
-define(FLAG_STDIO_MODE,       16#03). % see also `STDIO_*' macros
-define(FLAG_STDIO_SOCKET,     16#04).
-define(FLAG_STDERR_TO_STDOUT, 16#08).
-define(FLAG_PGROUP,           16#10).
-define(FLAG_TERM_PGROUP,      16#20).

%% }}}
%%----------------------------------------------------------
%% events {{{

%% event types
-define(TAG_EVENT_EXEC,     16#73). %<mode:8>  <id:64> <pid:32> + FDs
-define(TAG_EVENT_ERROR,    16#65). %<stage:8> <id:64> <errno:32>
-define(TAG_EVENT_EXIT,     16#78). %<zero:8>  <id:64> <code:32>
-define(TAG_EVENT_SIGNAL,   16#6b). %<zero:8>  <id:64> <signal:32>
-define(TAG_EVENT_SHUTDOWN, 16#74). %<zero:8+64> <nchildren:32>

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a unix subprocess supervisor.

-spec open(Options :: [Option]) ->
  {ok, handle()} | {error, badarg}
  when Option :: {shutdown_timeout, timeout()}
               | shutdown_kill
               | no_shutdown_kill.

open(Options) ->
  try lists:foldr(fun open_option/2, {infinity, false}, Options) of
    {Timeout, KillFlag} ->
      PrivDir = elf_library_dir(),
      ok = erl_ddll:load(PrivDir, ?DRIVER_SUP_NAME),
      UnixSupExeName = filename:join(PrivDir, ?DRIVER_SUP_EXE_NAME),
      DriverCommand = ?DRIVER_SUP_NAME ++ " " ++ UnixSupExeName,
      try open_port({spawn_driver, DriverCommand}, [binary]) of
        Port ->
          % `Timeout' and `KillFlag' are built very carefully, so this never
          % fails
          ok = shutdown_options(Port, Timeout, KillFlag),
          {ok, Port}
      catch
        error:Reason ->
          erl_ddll:unload(?DRIVER_SUP_NAME),
          {error, Reason}
      end
  catch
    _:_ ->
      {error, badarg}
  end.

%%----------------------------------------------------------
%% elf_library_dir() {{{

%% @doc Return path to the directory with shared libraries and executables for
%%   this application.

-spec elf_library_dir() ->
  file:filename().

elf_library_dir() ->
  case code:lib_dir(subproc, priv) of
    {error, bad_name} -> erlang:error({missing_application, subproc});
    PrivDir -> PrivDir
  end.

%% }}}
%%----------------------------------------------------------
%% open_option() {{{

%% @doc Fold workhorse to parse shutdown options to set when opening a master
%%   port.
%% @see open/1

-spec open_option(Option :: term(), Opts :: {timeout(), boolean()}) ->
  {timeout(), boolean()}.

open_option({shutdown_timeout, infinity}, {_OldTimeout, KillFlag}) ->
  {infinity, KillFlag};
open_option({shutdown_timeout, Timeout}, {_OldTimeout, KillFlag})
when is_integer(Timeout), Timeout > 0 ->
  {Timeout, KillFlag};
open_option(shutdown_kill, {Timeout, _OldKillFlag}) ->
  {Timeout, true};
open_option(no_shutdown_kill, {Timeout, _OldKillFlag}) ->
  {Timeout, false}.

%% }}}
%%----------------------------------------------------------

%% @doc Get pid of unix subprocess supervisor.

-spec pidof(handle()) ->
  subproc_unix:os_pid().

pidof(Port) ->
  <<PID:32>> = port_control(Port, 1, <<>>),
  PID.

%% @doc Close the channels used for communication with unix subprocess
%%   supervisor.
%%
%%   This causes the supervisor to terminate its subprocesses and exit, but
%%   none of the events will be received.
%%
%% @see shutdown/3
%% @see shutdown/1

-spec close(handle()) ->
  ok.

close(Port) ->
  try
    unlink(Port),
    port_close(Port),
    erl_ddll:unload(?DRIVER_SUP_NAME)
  catch
    % this could be caused by port already being closed, which is expected in
    % some cases
    error:badarg -> ignore
  end,
  ok.

%%%---------------------------------------------------------------------------
%%% sending requests
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% exec() {{{

%% @doc Execute a command and return its ID, OS PID, and file descriptors for
%%   STDIO.
%%
%%   NOTE: `term_pgroup' option causes `termsig' to be sent to whole process
%%   group on leader's termination.

-spec exec(handle(), file:filename(), [string()], Options :: [Option]) ->
    {ok, {subproc_id(), subproc_unix:os_pid(), STDIO}}
  | {error, RequestError | ExecError | EventError | badarg}
  when Option :: {stdio, Type :: socket | pipe,
                   Mode :: bidir | in | out | in_out}
               | stderr_to_stdout
               | pgroup
               | term_pgroup
               | {termsig, subproc_unix:signal()}
               | {ignore_signals, [subproc_unix:signal()]}
               | {nice, integer()}
               | {user, uid() | user()}
               | {group, gid() | group()}
               | {cd, file:filename()}
               | {argv0, file:filename()},
       STDIO :: {bidir, FDRW} | {in, FDR} | {out, FDW} | {in_out, {FDR, FDW}},
       FDRW :: subproc_unix:os_fd(),
       FDR :: subproc_unix:os_fd(),
       FDW :: subproc_unix:os_fd(),
       ExecError :: {Stage :: atom(), Error :: posix()},
       RequestError :: atom(),
       EventError :: bad_stdio_mode | unknown_event.

exec(Port, Command, Args, Options) ->
  try build_exec_request(Command, Args, Options) of
    Request ->
      case port_control(Port, 0, Request) of
        <<?TAG_ACK_OK:16, ID:64/integer>> ->
          case exec_result_event(Port, ID) of
            {exec, ID, STDIO, PID} ->
              {ok, {ID, PID, STDIO}};
            {exec_error, ID, Stage, Error} ->
              {error, {Stage, Error}};
            {error, Reason} -> % `bad_stdio_mode' or `unknown_event'
              {error, Reason}
          end;
        <<?TAG_ACK_REQ_ERROR:16, Error:8/signed-integer, _:56/bits>> ->
          {error, error_ack(Error)}
        % OS-level errors from subprocess spawning are sent as events
        % OS-level errors from sending a command cause port driver to
        % terminate in crash mode
      end
  catch
    error:stdio_pipe_bidir ->
      {error, stdio_pipe_bidir};
    error:bad_signal ->
      {error, bad_signal};
    _:_ ->
      {error, badarg}
  end.

%% @doc Wait for an event with result of a freshly sent exec request.

-spec exec_result_event(handle(), subproc_id()) ->
    {exec, subproc_id(), STDIO :: tuple(), subproc_unix:os_pid()}
  | {exec_error, subproc_id(), Stage :: atom(), Error :: posix()}
  | {error, bad_stdio_mode | unknown_event}.

exec_result_event(Port, ID) ->
  % this function is called immediately after an exec request was accepted;
  % the first event about `ID' will be either success or failure report
  receive
    {subproc_sup, Port, <<_Tag:8, _:8, ID:64, _:32>>, _FDs} = Event ->
      decode_event(Event)
  end.

%% }}}
%%----------------------------------------------------------
%% kill() {{{

%% @doc Send a kill request to unix subprocess supervisor.
%%
%%   A subprocess will be sent its default termination signal (`termsig'
%%   option from {@link exec/4}).

-spec kill(handle(), subproc_id()) ->
  ok | {error, nxchild | posix() | badarg}.

kill(Port, ID) when is_integer(ID) ->
  kill(Port, ID, default).

%% @doc Send a kill request to unix subprocess supervisor.

-spec kill(handle(), subproc_id(), default | subproc_unix:signal()) ->
  ok | {error, nxchild | bad_signal | posix() | badarg}.

kill(Port, ID, Signal) when is_integer(ID) ->
  try build_kill_request(ID, Signal) of
    Request ->
      case port_control(Port, 0, Request) of
        <<?TAG_ACK_OK:16, _:64/integer>> ->
          ok;
        <<?TAG_ACK_REQ_ERROR:16, Error:8/signed-integer, _:56/bits>> ->
          {error, error_ack(Error)};
        <<?TAG_ACK_OS_ERROR:16, Errno:32/signed-integer, _:32/bits>> ->
          {error, error_errno(Errno)}
      end
  catch
    _:_ ->
      {error, badarg}
  end.

%% }}}
%%----------------------------------------------------------
%% shutdown_options() {{{

%% @doc Set shutdown options for unix subprocess supervisor.
%%
%%   `Timeout' is a number of milliseconds for supervisor to wait for
%%   subprocesses to terminate before giving up and exiting. It can be an atom
%%   `infinity' to indicate that the supervisor should wait indefinitely.
%%
%%   If `KillFlag' is `true', after `Timeout' the supervisor sends `SIGKILL'
%%   signal to the subprocesses (process groups, if possible) that are still
%%   alive and waits another `Timeout' for them to exit. The second timeout is
%%   to handle processes in uninterruptible sleep (e.g. hanged on a file
%%   operation on NFS filesystem). Setting `KillFlag' to `true' has no effect
%%   when `Timeout' is `infinity'.
%%
%%   After all subprocesses terminate (or after timeout), supervisor sends
%%   a shutdown report event ({@link decode_event/1} returns it as
%%   {@type @{shutdown,AliveChildren :: non_neg_integer()@}}) and exits.
%%
%% @see shutdown/3
%% @see shutdown/1

-spec shutdown_options(handle(), timeout(), boolean()) ->
  ok | {error, badarg}.

shutdown_options(Port, Timeout, KillFlag) ->
  % `Timeout' is in milliseconds or `infinity'
  try build_shutdown_options_request(Timeout, KillFlag) of
    Request ->
      % this request should never fail
      <<?TAG_ACK_OK:16, _:64/integer>> = port_control(Port, 0, Request),
      ok
  catch
    _:_ ->
      {error, badarg}
  end.

%% }}}
%%----------------------------------------------------------
%% shutdown() {{{

%% @doc Set unix subprocess supervisor shutdown options and order it to
%%   terminate.
%%
%%   This is a convenience wrapper for {@link shutdown_options/3} and
%%   {@link shutdown/1} functions.
%%
%%   Shutdown procedure is described in {@link shutdown_options/3}.
%%
%% @see shutdown_options/3
%% @see shutdown/1

-spec shutdown(handle(), timeout(), boolean()) ->
  ok | {error, badarg}.

shutdown(Port, Timeout, KillFlag) ->
  case shutdown_options(Port, Timeout, KillFlag) of
    ok -> shutdown(Port);
    {error, Reason} -> {error, Reason}
  end.

%% @doc Order unix subprocess supervisor to terminate.
%%
%%   Shutdown procedure is described in {@link shutdown_options/3}.
%%
%%   Port is still open after sending this request, and port owner still
%%   receives normal events ({@type event_message()}).
%%
%% @see shutdown_options/3
%% @see shutdown/3
%% @see close/1

-spec shutdown(handle()) ->
  ok.

shutdown(Port) ->
  Request = build_shutdown_request(),
  % this request should never fail
  <<?TAG_ACK_OK:16, _:64/integer>> = port_control(Port, 0, Request),
  ok.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% decoding events
%%%---------------------------------------------------------------------------

%% @doc Decode event received from unix subprocess supervisor.

-spec decode_event(event_message()) ->
    ExecEvent
  | ExecErrorEvent
  | ExitEvent
  | SignalEvent
  | ShutdownEvent
  | {error, bad_stdio_mode | unknown_event}
  when ExecEvent :: {exec, subproc_id(), STDIO, subproc_unix:os_pid()},
       ExecErrorEvent :: {exec_error, subproc_id(),
                           Stage :: atom(), Error :: posix()},
       ExitEvent :: {exit, subproc_id(), ExitCode :: 0 .. 255},
       SignalEvent :: {signal, subproc_id(),
                        {subproc_unix:signal_number(),
                          subproc_unix:signal_name()}},
       ShutdownEvent :: {shutdown, AliveChildren :: non_neg_integer()},
       STDIO :: {bidir, FDRW} | {in, FDR} | {out, FDW} | {in_out, {FDR, FDW}},
       FDRW :: subproc_unix:os_fd(),
       FDR :: subproc_unix:os_fd(),
       FDW :: subproc_unix:os_fd().

decode_event({subproc_sup, _Port, EventData, FDs} = _Event) ->
  case EventData of
    <<?TAG_EVENT_EXEC:8, Mode:8, ID:64, PID:32>> ->
      % XXX: Erlang and underlying C code have different perspectives on what
      % is "in" and "out", so we're swapping the terms here
      case {Mode, FDs} of
        {0, [FDRW]}     -> {exec, ID, {bidir, FDRW}, PID};
        {1, [FDW]}      -> {exec, ID, {out, FDW}, PID};
        {2, [FDR]}      -> {exec, ID, {in, FDR}, PID};
        {3, [FDW, FDR]} -> {exec, ID, {in_out, {FDR, FDW}}, PID};
        _ ->
          lists:foreach(fun subproc_unix:close/1, FDs),
          {error, bad_stdio_mode}
      end;
    <<?TAG_EVENT_ERROR:8, Stage:8, ID:64, Errno:32/signed>> ->
      {exec_error, ID, error_stage(Stage), error_errno(Errno)};
    <<?TAG_EVENT_EXIT:8, _:8, ID:64, Code:32/signed>> ->
      {exit, ID, Code};
    <<?TAG_EVENT_SIGNAL:8, _:8, ID:64, Signal:32>> ->
      {signal, ID, {Signal, signal_name(Signal)}};
    <<?TAG_EVENT_SHUTDOWN:8, _:8, _:64, NChildren:32>> ->
      {shutdown, NChildren};
    _ ->
      lists:foreach(fun subproc_unix:close/1, FDs),
      {error, unknown_event}
  end.

%%%---------------------------------------------------------------------------
%%% formatting errors
%%%---------------------------------------------------------------------------

%% @doc Format a reason from error tuple as a usable error message.

-spec format_error(Reason :: term()) ->
  string().

format_error(badarg) ->
  "bad argument";

%% OS level failure of `exec()'
format_error({Stage, PosixError}) ->
  StageDescr = case Stage of
    confirm_channel -> "error reporting channel";
    pipe_in  -> "pipe() for STDIN";
    pipe_out -> "pipe() for STDOUT";
    socketpair_in  -> "socketpair() for STDIN";
    socketpair_out -> "socketpair() for STDOUT";
    fork   -> "fork()";
    setpriority -> "setpriority()";
    setgid -> "setgid()";
    setuid -> "setuid()";
    chdir  -> "chdir()";
    exec   -> "exec()";
    unrecognized_stage -> "<unrecognized stage>"
  end,
  "exec() error at " ++ StageDescr ++ ": " ++ inet:format_error(PosixError);

%% request got a NAK with this error (`exec()', `kill()')
format_error(unknown_devel) ->
  "unexpected development error (`subproc' library's fault)";
format_error(no_child_space) ->
  "can't register more child processes";
format_error(request_too_big) ->
  "request was too big";
format_error(parse_error) ->
  "request was ill-formed (`subproc' library's fault)";
format_error(bad_request_header) ->
  "invalid request packet header (`subproc' library's fault)";
format_error(bad_signal) ->
  "invalid signal number or name";
format_error(stdio_pipe_bidir) ->
  "bidirectional STDIO unsupported with pipes";
format_error(nxuser) ->
  "no such user";
format_error(nxgroup) ->
  "no such group";
format_error(bad_option) ->
  "unrecognized exec option tag (`subproc' library's fault)";
format_error(nxchild) ->
  "no such child process";
format_error(unknown) ->
  "unknown NAK error code (`subproc' library's fault)";

%% ill-formed events (`decode_event()')
format_error(bad_stdio_mode) ->
  "invalid STDIO mode in exec event (`subproc' library's fault)";
format_error(unknown_event) ->
  "unrecognized event (`subproc' library's fault)";

%% other errors (`kill()')
format_error(PosixError) when is_atom(PosixError) ->
  inet:format_error(PosixError).

%%%---------------------------------------------------------------------------
%%% helpers: building requests
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% exec request

%% @doc Build an exec request.

-spec build_exec_request(file:filename(), [string()], [term()]) ->
  request().

build_exec_request(Command, Args, Options) ->
  RunOpts = exec_options(Options),
  Flags = build_exec_flags(RunOpts),
  Request = [
    % header
    <<?TAG_REQ_EXEC:8, Flags:8>>,
    % command and its arguments
    pack_string(Command),
    <<(length(Args)):16>>, [pack_string(A) || A <- Args],
    % exec options
    build_exec_options(RunOpts)
  ],
  [<<(iolist_size(Request)):32>> | Request].

%%----------------------------------------------------------
%% exec options container {{{

-record(exec, {
  env :: term(), % TODO: define me
  termsig = close :: close | subproc_unix:signal(),
  ignore_signals = [] :: [subproc_unix:signal()],
  stdio = default :: default | bidir | in | out | in_out,
  stderr_to_stdout = false :: boolean(),
  socket = false :: boolean(),
  pgroup = false :: boolean(),
  term_pgroup = false :: boolean(), % killpg() on shutdown
  user  :: undefined | uid() | user(),
  group :: undefined | gid() | group(),
  nice  :: undefined | integer(),
  cwd   :: undefined | file:filename(),
  argv0 :: undefined | file:filename()
}).

%% }}}
%%----------------------------------------------------------
%% exec_options() {{{

%% @doc Parse exec options to a usable structure.

-spec exec_options(Options :: [Option]) ->
  #exec{}
  when Option :: atom() | {atom(), term()} | {atom(), term(), term()}.

exec_options(Options) ->
  case lists:foldr(fun exec_option/2, #exec{}, Options) of
    Opts = #exec{stdio = default, socket = true} -> Opts#exec{stdio = bidir};
    Opts = #exec{stdio = default, socket = false} -> Opts#exec{stdio = in_out};
    Opts -> Opts
  end.

%% @doc Fold workhorse for {@link exec_options/1}.
%%
%% @see exec_options/1

-spec exec_option(Option :: term(), #exec{}) ->
  #exec{}.

exec_option({stdio, Type, Mode}, Opts)
when Type == socket orelse Type == pipe,
     Mode == bidir orelse Mode == in orelse Mode == out orelse Mode == in_out ->
  Opts#exec{stdio = Mode, socket = (Type == socket)};
exec_option(stderr_to_stdout, Opts) ->
  Opts#exec{stderr_to_stdout = true};
exec_option(pgroup, Opts) ->
  Opts#exec{pgroup = true};
exec_option(term_pgroup, Opts) ->
  Opts#exec{term_pgroup = true};
exec_option({termsig, Signal}, Opts) when is_atom(Signal); is_integer(Signal) ->
  Opts#exec{termsig = Signal};
exec_option({ignore_signals, SignalList}, Opts) ->
  true = lists:all(fun(S) -> is_atom(S) orelse is_integer(S) end, SignalList),
  Opts#exec{ignore_signals = SignalList};
exec_option({nice, Nice}, Opts) when is_integer(Nice) ->
  Opts#exec{nice = Nice};
exec_option({user, User}, Opts) when is_integer(User); is_list(User) ->
  Opts#exec{user = User};
exec_option({group, Group}, Opts) when is_integer(Group); is_list(Group) ->
  Opts#exec{group = Group};
exec_option({cd, Dir}, Opts) when is_list(Dir) ->
  Opts#exec{cwd = Dir};
exec_option({argv0, Name}, Opts) when is_list(Name) ->
  Opts#exec{argv0 = Name}.

%% @private
%% @doc Check if a value is an option for {@link exec()}.
%%
%%   The function does not validate value of the option, only checks if it is
%%   applicable.
%%
%% @see exec_option/2

-spec is_option(Option :: term()) ->
  boolean().

is_option({stdio, _, _}) -> true;
is_option(stderr_to_stdout) -> true;
is_option(pgroup)      -> true;
is_option(term_pgroup) -> true;
is_option({termsig, _}) -> true;
is_option({ignore_signals, _}) -> true;
is_option({nice, _})  -> true;
is_option({user, _})  -> true;
is_option({group, _}) -> true;
is_option({cd, _})    -> true;
is_option({argv0, _}) -> true;
is_option(_Value) -> false.

%% @private
%% @doc Check what STDIO mode will be formed from exec options.

-spec stdio_mode(Options :: [term()]) ->
  bidir | in | out | in_out | {error, badarg}.

stdio_mode(Options) ->
  try exec_options(Options) of
    #exec{stdio = Mode} -> Mode
  catch
    _:_ -> {error, badarg}
  end.

%% }}}
%%----------------------------------------------------------
%% build_exec_flags() {{{

%% @doc Prepare flags for exec request.

-spec build_exec_flags(#exec{}) ->
  byte().

build_exec_flags(Opts = #exec{}) ->
  STDIOMode = case Opts of
    #exec{stdio = bidir, socket = true} -> ?STDIO_BIDIR;
    #exec{stdio = bidir, socket = false} -> erlang:error(stdio_pipe_bidir);
    % XXX: `erlang:open_port()' defines "in" and "out" terms from BEAM's
    % perspective, but here underlying C code defines them from child process'
    % perspective, which is the opposite
    #exec{stdio = in} -> ?STDIO_OUT;
    #exec{stdio = out} -> ?STDIO_IN;
    #exec{stdio = in_out} -> ?STDIO_IN_OUT
  end,
  STDIOType = case Opts of
    #exec{socket = true} -> ?FLAG_STDIO_SOCKET;
    _ -> 0
  end,
  CaptureSTDERR = case Opts of
    #exec{stderr_to_stdout = true} -> ?FLAG_STDERR_TO_STDOUT;
    _ -> 0
  end,
  ProcGroup = case Opts of
    #exec{pgroup = true, term_pgroup = true} ->
      ?FLAG_PGROUP bor ?FLAG_TERM_PGROUP;
    #exec{pgroup = true, term_pgroup = false} ->
      ?FLAG_PGROUP;
    #exec{pgroup = false} ->
      0
  end,
  _Result = STDIOMode bor STDIOType bor CaptureSTDERR bor ProcGroup.

%% }}}
%%----------------------------------------------------------
%% build_exec_options() {{{

%% @doc Prepare option segment of {@type request()} for exec request.

-spec build_exec_options(#exec{}) ->
  iolist().

build_exec_options(Opts = #exec{}) ->
  OptTermSig = case Opts of
    #exec{termsig = close} -> [];
    #exec{termsig = SigNum} when is_number(SigNum) -> <<16#74:8, SigNum:8>>;
    #exec{termsig = SigName} when is_atom(SigName) ->
      try subproc_unix:signal_number(SigName) of
        SigNum -> <<16#74:8, SigNum:8>>
      catch
        error:badarg -> erlang:error(bad_signal)
      end
  end,
  SigIgnMask = make_signal_mask(Opts#exec.ignore_signals, 0),
  OptSigIgn = <<16#73:8, SigIgnMask:64>>,
  OptNice = case Opts of
    #exec{nice = undefined} -> [];
    #exec{nice = Nice} -> <<16#70:8, Nice:8>>
  end,
  OptUser = case Opts of
    #exec{user = undefined} -> [];
    #exec{user = UID} when is_integer(UID), UID >= 0 -> <<16#75:8, UID:16>>;
    #exec{user = User} -> pack_tagged_string(16#55, User)
  end,
  OptGroup = case Opts of
    #exec{group = undefined} -> [];
    #exec{group = GID} when is_integer(GID), GID >= 0 -> <<16#67:8, GID:16>>;
    #exec{group = Group} -> pack_tagged_string(16#47, Group)
  end,
  OptCwd = case Opts of
    #exec{cwd = undefined} -> [];
    #exec{cwd = Dir} -> pack_tagged_string(16#43, Dir)
  end,
  OptArgv0 = case Opts of
    #exec{argv0 = undefined} -> [];
    #exec{argv0 = Name} -> pack_tagged_string(16#30, Name)
  end,
  _Result = [
    OptTermSig, OptSigIgn, OptCwd, OptUser, OptGroup, OptNice, OptArgv0
  ].

%% @doc Make a signal mask from list of signals (names and/or numbers).

-spec make_signal_mask([subproc_unix:signal()], non_neg_integer()) ->
  non_neg_integer().

make_signal_mask([] = _SignalList, Mask) ->
  Mask;
make_signal_mask([SigNum | Rest], Mask)
when is_integer(SigNum), SigNum > 0, SigNum =< 64 ->
  make_signal_mask(Rest, Mask bor (1 bsl (SigNum - 1)));
make_signal_mask([SigName | Rest], Mask) when is_atom(SigName) ->
  try subproc_unix:signal_number(SigName) of
    SigNum -> make_signal_mask(Rest, Mask bor (1 bsl (SigNum - 1)))
  catch
    _:_ -> erlang:error(bad_signal)
  end;
make_signal_mask(_SignalList, _Mask) ->
  erlang:error(bad_signal).

%% }}}
%%----------------------------------------------------------
%% string packing {{{

%% @doc Encode a tagged string for {@type request()}.

-spec pack_tagged_string(byte(), iolist()) ->
  iolist().

pack_tagged_string(Tag, String) ->
  StrLen = iolist_size(String),
  [<<Tag:8, StrLen:16>>, String].

%% @doc Encode a string for {@type request()}.

-spec pack_string(iolist()) ->
  iolist().

pack_string(String) ->
  StrLen = iolist_size(String),
  [<<StrLen:16>>, String].

%% }}}
%%----------------------------------------------------------

%%----------------------------------------------------------
%% kill request

%% @doc Build a kill request.

-spec build_kill_request(subproc_id(), subproc_unix:signal()) ->
  request().

build_kill_request(ID, Signal) ->
  SigNum = case Signal of
    default -> 0;
    _ when is_atom(Signal) -> subproc_unix:signal_number(Signal);
    _ when is_integer(Signal) -> Signal
  end,
  % 10 bytes = (8 bits + 8 bits + 64 bits) / 8 (bits per byte)
  <<10:32, ?TAG_REQ_KILL:8, SigNum:8, ID:64>>.

%%----------------------------------------------------------
%% set shutdown options request

%% @doc Build a "set shutdown options" request.

-spec build_shutdown_options_request(timeout(), boolean()) ->
  request().

build_shutdown_options_request(Timeout, KillFlag) ->
  Flags = case KillFlag of
    true  -> 16#01;
    false -> 16#00
  end,
  % 6 bytes = (8 bits + 8 bits + 32 bits) / 8 (bits per byte)
  case Timeout of
    _ when is_integer(Timeout), Timeout > 0, Timeout =< 16#ffffffff ->
      <<6:32, ?TAG_REQ_SHUT_OPTS:8, Flags:8, Timeout:32>>;
    infinity ->
      <<6:32, ?TAG_REQ_SHUT_OPTS:8, Flags:8, 0:32>>
  end.

%%----------------------------------------------------------
%% shutdown request

%% @doc Build a shutdown request.

-spec build_shutdown_request() ->
  request().

build_shutdown_request() ->
  <<2:32, ?TAG_REQ_SHUTDOWN:8, 0:8>>.

%%%---------------------------------------------------------------------------
%%% helpers: translating integer codes to atoms
%%%---------------------------------------------------------------------------

%% @doc Translate NAK error code to a more descriptive atom.

-spec error_ack(ErrorCode :: integer()) ->
  atom().

error_ack(-128) -> unknown_devel;    % a situation that should never happen (development error)
error_ack(-127) -> no_child_space;   % can't register more children
error_ack(-126) -> request_too_big;  % request was too big
error_ack(-1) -> parse_error;        % general request parse error
error_ack(-2) -> bad_request_header; % invalid request packet header
error_ack(-3) -> bad_signal;         % invalid signal number
error_ack(-4) -> stdio_pipe_bidir;   % bidirectional STDIO requested for pipe
error_ack(-5) -> nxuser;             % no such user
error_ack(-6) -> nxgroup;            % no such group
error_ack(-7) -> bad_option;         % unrecognized exec option tag
error_ack(-8) -> nxchild;            % no such child process
error_ack(_)  -> unknown.

%% @doc Translate exec error stage (integer) to a more descriptive atom.

-spec error_stage(Stage :: integer()) ->
  atom().

error_stage(0)  -> confirm_channel;
error_stage(1)  -> pipe_in;
error_stage(2)  -> pipe_out;
error_stage(3)  -> socketpair_in;
error_stage(4)  -> socketpair_out;
error_stage(5)  -> fork;
error_stage(6)  -> setpriority;
error_stage(7)  -> setgid;
error_stage(8)  -> setuid;
error_stage(9)  -> chdir;
error_stage(10) -> exec;
error_stage(_)  -> unrecognized_stage.

%% @doc Translate `errno' value (integer) to an atom.

-spec error_errno(integer()) ->
  atom().

error_errno(Errno) ->
  subproc_unix:errno_to_posix(Errno).

%% @doc Translate signal number to an atom.

-spec signal_name(integer()) ->
  atom().

signal_name(Signal) ->
  % TODO: on error return something instead of dying
  subproc_unix:signal_name(Signal).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
