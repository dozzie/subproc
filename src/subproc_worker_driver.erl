%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Functions for working with worker port driver directly.
%%%
%%% @todo A function to inform port that its child exited/got killed (this
%%%   should immediately close FDW descriptor, but what with FDR? on one hand,
%%%   there could be some pending data to read, but on the other hand,
%%%   a subprocess could keep the descriptor open and still produce data
%%%   there; it could be a port option).
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_worker_driver).

%% public interface
-export([open/2, close/1, close/2]).
-export([send/2, recv/2, recv/3]).
-export([setopts/2, getopts/2, controlling_process/2, status/1]).
-export([terminated/2]).
-export([valid_options/1]).
-export([format_error/1]).

%%%---------------------------------------------------------------------------
%%% types

%% for port driver
-define(DRIVER_NAME, "subproc_drv").

-define(MAX_SINT, 16#7fffffff).
-define(MAX_UINT, 16#ffffffff).

-type option_name() :: mode | active | exit_status | packet | packet_size.

-type open_option() :: {pid, subproc:os_pid()}
                     | {close, boolean()}
                     | {close_on_exit, boolean()}.
%% Options that can only be specified at `open_port()' time.

-record(opts, {
  mode :: list | binary | undefined,
  active :: true | false | once | undefined,
  exit_status :: true | false | undefined,
  packet :: raw | 1 | 2 | 4 | line | undefined,
  packet_size :: pos_integer() | undefined,
  close :: boolean() | undefined,
  close_on_exit :: boolean() | undefined,
  pid :: subproc:os_pid() | undefined
}).

%%%---------------------------------------------------------------------------
%%% opening and closing the port
%%%---------------------------------------------------------------------------

%% @doc Open a port for reading/writing to/from subprocess.

-spec open(STDIO, [subproc:read_option() | open_option()]) ->
  {ok, subproc:handle()} | {error, badarg | system_limit | subproc:posix()}
  when STDIO :: {bidir, FDRW} | {in, FDR} | {out, FDW} | {in_out, {FDR, FDW}},
       FDRW :: subproc:os_fd(),
       FDR :: subproc:os_fd(),
       FDW :: subproc:os_fd().

open(STDIO, Options) ->
  Defaults = #opts{
    mode = list,
    active = false,
    exit_status = false,
    packet = raw,
    packet_size = 16384, % 16kB
    close = true,        % see also `#opts{}' definition in `subproc_master'
    close_on_exit = true % see also `#opts{}' definition in `subproc_master'
  },
  case {valid_stdio(STDIO), options(Options, Defaults)} of
    {true, {ok, Opts = #opts{pid = PID, close = AutoClose,
                             close_on_exit = CloseOnExit}} } ->
      PrivDir = elf_library_dir(),
      ok = erl_ddll:load(PrivDir, ?DRIVER_NAME),
      try open_port({spawn_driver, ?DRIVER_NAME}, [binary]) of
        Port ->
          ok = ioctl_setfd(Port, STDIO, PID, AutoClose, CloseOnExit),
          ok = ioctl_setopts(Port, Opts),
          {ok, Port}
      catch
        error:Reason ->
          erl_ddll:unload(?DRIVER_NAME),
          {error, Reason}
      end;
    {_, _} ->
      % invalid `STDIO' or `Options'
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
%% valid_stdio() {{{

%% @doc Validate `STDIO' argument for opening port ({@link open/2}).

-spec valid_stdio(tuple()) ->
  boolean().

valid_stdio(STDIO) ->
  case STDIO of
    {bidir, U} when is_integer(U), U >= 0, U =< ?MAX_SINT -> true;
    {in,    R} when is_integer(R), R >= 0, R =< ?MAX_SINT -> true;
    {out,   W} when is_integer(W), W >= 0, W =< ?MAX_SINT -> true;
    {in_out, {R, W}} when is_integer(R), R >= 0, R =< ?MAX_SINT,
                          is_integer(W), W >= 0, W =< ?MAX_SINT -> true;
    _ -> false
  end.

%% }}}
%%----------------------------------------------------------

%% @doc Close the port handle.
%%
%%   Note that while this function closes file descriptors, it does not
%%   send subprocess any signal and does not wait for its termination.
%%   After calling this function, there's no way to read subprocess' exit
%%   code.
%%
%%   To wait for subprocess to terminate, call `close(Port, read)' or
%%   `close(Port, read_write)' and then call `recv(Port, _)' in loop.

-spec close(subproc:handle()) ->
  ok.

close(Port) ->
  try
    unlink(Port),
    port_close(Port),
    erl_ddll:unload(?DRIVER_NAME)
  catch
    % this could be caused by port already being closed, which is expected in
    % some cases
    error:badarg -> ignore
  end,
  ok.

%% @doc Close reading and/or writing descriptors, but don't terminate the
%%   subprocess.

-spec close(subproc:handle(), read | write | read_write) ->
  ok | {error, badarg}.

close(Port, How) ->
  Request = case How of
    read -> <<1>>;
    write -> <<2>>;
    read_write -> <<3>>
  end,
  try port_control(Port, 3, Request) of
    _ -> ok
  catch
    _:_ -> {error, badarg}
  end.

%%%---------------------------------------------------------------------------
%%% input/output
%%%---------------------------------------------------------------------------

%% @doc Send data to the subprocess.

-spec send(subproc:handle(), iolist()) ->
  ok | {error, closed | subproc:posix()}.

send(Port, Data) ->
  port_command(Port, Data),
  reply_wait(Port, 100).

%% @doc Read data from the subprocess.
%%
%%   Special errors:
%%   <ul>
%%     <li>`closed' -- reading descriptor closed</li>
%%     <li>`eintr' -- socket mode changed to active while `recv()'</li>
%%     <li>`ealready' -- another `recv()' call already in progress</li>
%%     <li>`einval' -- socket is in active mode</li>
%%   </ul>

-spec recv(subproc:handle(), non_neg_integer()) ->
    {ok, Data :: string() | binary()}
  | eof
  | {terminated, Exit | Signal}
  | {error, closed | subproc:posix()}
  when Exit :: {exit, subproc:exit_code()},
       Signal :: {signal, subproc:signal_number(), subproc:signal_name()}.

recv(Port, Length) ->
  recv(Port, Length, infinity).

%% @doc Read data from the subprocess.
%%
%%   Notable errors:
%%   <ul>
%%     <li>`timeout' -- nothing to read</li>
%%     <li>`closed' -- reading descriptor closed</li>
%%     <li>`eintr' -- socket mode changed to active while `recv()'</li>
%%     <li>`ealready' -- another `recv()' call already in progress</li>
%%     <li>`einval' -- socket is in active mode</li>
%%   </ul>

-spec recv(subproc:handle(), non_neg_integer(), timeout()) ->
    {ok, Data :: string() | binary()}
  | eof
  | {terminated, Exit | Signal}
  | {error, closed | timeout | subproc:posix()}
  when Exit :: {exit, subproc:exit_code()},
       Signal :: {signal, subproc:signal_number(), subproc:signal_name()}.

recv(Port, Length, infinity = _Timeout) ->
  port_control(Port, 4, <<Length:32>>),
  reply_wait(Port, 100);
recv(Port, Length, Timeout) when is_integer(Timeout) ->
  port_control(Port, 4, <<Length:32>>),
  receive
    {subproc_reply, Port, {ok, Data}} -> {ok, Data};
    {subproc_reply, Port, eof} -> eof;
    {subproc_reply, Port, {error, Reason}} -> {error, Reason}
  after Timeout ->
      try port_control(Port, 5, <<>>) of % cancel recv()
        _ ->
          receive
            {subproc_reply, Port, {ok, Data}} -> {ok, Data};
            {subproc_reply, Port, eof} -> eof;
            {subproc_reply, Port, {error, Reason}} -> {error, Reason}
          after 0 ->
              {error, timeout}
          end
      catch
        % port died on us while we were waiting for the reply
        _:_ -> {error, closed}
      end
  end.

%%%---------------------------------------------------------------------------
%%% options
%%%---------------------------------------------------------------------------

%% @doc Set one or more options for a port.

-spec setopts(subproc:handle(), [subproc:read_option()]) ->
  ok | {error, badarg}.

setopts(Port, [{active, Mode}] = _Options) ->
  % a shorthand that skips all parsing for setting `{active,once}' mode
  try
    ioctl_setactive(Port, Mode)
  catch
    _:_ -> {error, badarg}
  end;
setopts(Port, Options) ->
  case options(Options, #opts{}) of
    {ok, Opts = #opts{pid = undefined, close = undefined,
                      close_on_exit = undefined}} ->
      % try..catch to match `getopts()' behaviour on invalid port
      try
        ok = ioctl_setopts(Port, Opts)
      catch
        _:_ -> {error, badarg}
      end;
    {ok, _Opts} ->
      {error, badarg};
    {error, badarg} ->
      {error, badarg}
  end.

%% @doc Get one or more options for a port.

-spec getopts(subproc:handle(), [option_name() | pid]) ->
  {ok, [subproc:read_option() | {pid, PID}]} | {error, badarg}
  when PID :: subproc:os_pid() | undefined.

getopts(Port, Options) ->
  try lists:foldr(fun get_option/2, {[], ioctl_getopts(Port)}, Options) of
    {Result, _Opts} ->
      {ok, Result}
  catch
    _:_ ->
      {error, badarg}
  end.

%% @doc Fold workhorse for {@link getopts/2}.

-spec get_option(option_name() | pid, Acc :: {[Option], #opts{}}) ->
  {[Option], #opts{}}
  when Option :: subproc:read_option() | {pid, subproc:os_pid() | undefined}.

get_option(mode = Name, {OptList, Opts = #opts{mode = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(active = Name, {OptList, Opts = #opts{active = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(exit_status = Name, {OptList, Opts = #opts{exit_status = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(packet = Name, {OptList, Opts = #opts{packet = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(packet_size = Name, {OptList, Opts = #opts{packet_size = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(pid = Name, {OptList, Opts = #opts{pid = Value}}) ->
  {[{Name, Value} | OptList], Opts}.

%% @doc Inform the port that its child process terminated.

-spec terminated(subproc:handle(), Exit | Signal) ->
  ok | {error, badarg}
  when Exit :: {exit, subproc:exit_code()},
       Signal :: {signal, subproc:signal_number(), subproc:signal_name()}.

terminated(Port, {_, _} = TermInfo) ->
  % this function is called from owner of master port, try hard not to die on
  % closed port here
  try ioctl_terminated(Port, TermInfo) of
    _ -> ok
  catch
    _:_ -> {error, badarg}
  end.

%% @doc Check exit status of the port's child process.

-spec status(subproc:handle()) ->
    running
  | {exit, subproc:exit_code()}
  | {signal, {subproc:signal_number(), subproc:signal_name()}}
  | undefined
  | {error, badarg}.

status(Port) ->
  try
    ioctl_status(Port)
  catch
    _:_ -> {error, badarg}
  end.

%% @doc Assign a new owner to a port.

-spec controlling_process(subproc:handle(), pid()) ->
  ok | {error, not_owner | closed | badarg}.

controlling_process(Port, Pid) ->
  try erlang:port_info(Port, connected) of
    {connected, Pid} ->
      ok; % already the owner
    {connected, Owner} when Owner /= self() ->
      {error, not_owner};
    {connected, _OldOwner} ->
      try
        port_connect(Port, Pid),
        unlink(Port),
        ok
      catch
        _:_ ->
          {error, closed}
      end;
    undefined ->
      {error, closed}
  catch
    _:_ ->
      {error, badarg}
  end.

%%%---------------------------------------------------------------------------
%%% formatting errors
%%%---------------------------------------------------------------------------

%% @doc Format a reason from error tuple as a usable error message.

-spec format_error(Reason :: term()) ->
  string().

format_error(badarg) ->
  "bad argument";
format_error(closed) ->
  "file descriptor closed";
format_error(timeout) ->
  "operation timed out";
format_error(not_owner) ->
  "not the owner of the port";

format_error(system_limit) ->
  "too many spawned ports";

format_error(PosixError) ->
  inet:format_error(PosixError).

%%%---------------------------------------------------------------------------
%%% port monitor
%%%---------------------------------------------------------------------------

%% @doc Port monitor routine that waits for the port to reply.
%%
%%   If the ports dies silently before sending an ACK/NAK, `{error,closed}'
%%   is returned.

-spec reply_wait(subproc:handle(), timeout()) ->
  Reply :: term() | {error, closed}.

reply_wait(Port, Interval) ->
  receive
    {subproc_reply, Port, Reply} -> Reply
  after Interval ->
      case erlang:port_info(Port, connected) of
        {connected, _} -> reply_wait(Port, Interval); % still alive
        undefined -> {error, port_closed}
      end
  end.

%%%---------------------------------------------------------------------------
%%% port ioctl
%%%---------------------------------------------------------------------------

%% @doc Initialize the port with file handles.
%%
%%   Reinitializing a port is not possible and causes `error:badarg' crash.

-spec ioctl_setfd(subproc:handle(), subproc:stdio(),
                  subproc:os_pid() | undefined, boolean(), boolean()) ->
  ok.

ioctl_setfd(Port, STDIO, PID, AutoClose, CloseOnExit) ->
  case STDIO of
    {bidir, FDR = FDW} -> ok;
    {in,  FDR} -> FDW = -1;
    {out, FDW} -> FDR = -1;
    {in_out, {FDR, FDW}} -> ok
  end,
  case PID of
    undefined -> PIDNum = 0;
    PIDNum when is_integer(PIDNum) -> ok
  end,
  AutoCloseFlag = case AutoClose of
    true -> 1;
    false -> 0
  end,
  CloseOnExitFlag = case CloseOnExit of
    true -> 1;
    false -> 0
  end,
  Request = <<FDR:32, FDW:32, PIDNum:32, AutoCloseFlag:8, CloseOnExitFlag:8>>,
  port_control(Port, 0, Request),
  ok.

%% @doc Inform the port that its child process terminated.

-spec ioctl_terminated(subproc:handle(), Exit | Signal) ->
  ok
  when Exit :: {exit, subproc:exit_code()},
       Signal :: {signal, subproc:signal_number(), subproc:signal_name()}.

ioctl_terminated(Port, {exit, ExitCode}) ->
  port_control(Port, 6, <<1:8, ExitCode:8>>),
  ok;
ioctl_terminated(Port, {signal, {SigNum, _SigName}}) ->
  port_control(Port, 6, <<2:8, SigNum:8>>),
  ok.

%% @doc Check stauts of the port's subprocess.

-spec ioctl_status(subproc:handle()) ->
    running
  | {exit, subproc:exit_code()}
  | {signal, {subproc:signal_number(), subproc:signal_name()}}
  | undefined.

ioctl_status(Port) ->
  case port_control(Port, 7, <<>>) of
    <<0:8, _:8>> -> undefined;
    <<1:8, _:8>> -> running;
    <<2:8, ExitCode:8>> -> {exit, ExitCode};
    <<3:8, SigNum:8>> -> {signal, {SigNum, subproc_unix:signal_name(SigNum)}}
  end.

%% @doc Set port options.
%%
%%   PID, autoclose, and close on exit flags, even if defined, are ignored, as
%%   they're only allowed to be set with {@link ioctl_setfd/5}.

-spec ioctl_setopts(subproc:handle(), #opts{}) ->
  ok.

ioctl_setopts(Port, Options) ->
  port_control(Port, 1, [
    setopts_read_mode(Options),
    %setopts_exit_status_mode(Options), % TODO
    setopts_data_mode(Options),
    setopts_packet_mode(Options),
    setopts_packet_size(Options)
  ]),
  ok.

%% @doc Shorthand for setting port reading mode.
%%
%% @see ioctl_setopts/2

-spec ioctl_setactive(subproc:handle(), true | false | once) ->
  ok.

ioctl_setactive(Port, false = _Active) ->
  port_control(Port, 1, <<1:8, 0:8, 0:8, 0:32>>),
  ok;
ioctl_setactive(Port, true = _Active) ->
  port_control(Port, 1, <<2:8, 0:8, 0:8, 0:32>>),
  ok;
ioctl_setactive(Port, once = _Active) ->
  port_control(Port, 1, <<3:8, 0:8, 0:8, 0:32>>),
  ok.

%%----------------------------------------------------------
%% setopts data formatters {{{

%% @doc Encode read mode (`{active,_}').

-spec setopts_read_mode(Opts :: #opts{}) ->
  binary().

setopts_read_mode(#opts{active = undefined}) -> <<0:8>>;
setopts_read_mode(#opts{active = false}) -> <<1:8>>;
setopts_read_mode(#opts{active = true})  -> <<2:8>>;
setopts_read_mode(#opts{active = once})  -> <<3:8>>.

%% @doc Encode exit status mode (`{exit_status,_}').

-spec setopts_exit_status_mode(Opts :: #opts{}) ->
  binary().

setopts_exit_status_mode(#opts{exit_status = undefined}) -> <<0:8>>;
setopts_exit_status_mode(#opts{exit_status = false}) -> <<1:8>>;
setopts_exit_status_mode(#opts{exit_status = true})  -> <<2:8>>.

%% @doc Encode type of data returned from reads.

-spec setopts_data_mode(Opts :: #opts{}) ->
  binary().

setopts_data_mode(#opts{mode = undefined}) -> <<0:8>>;
setopts_data_mode(#opts{mode = list})   -> <<1:8>>;
setopts_data_mode(#opts{mode = binary}) -> <<2:8>>.

%% @doc Encode packet decoding mode.

-spec setopts_packet_mode(Opts :: #opts{}) ->
  binary().

setopts_packet_mode(#opts{packet = undefined}) -> <<0:8>>;
setopts_packet_mode(#opts{packet = raw})  -> <<1:8>>;
setopts_packet_mode(#opts{packet = 1})    -> <<2:8>>;
setopts_packet_mode(#opts{packet = 2})    -> <<3:8>>;
setopts_packet_mode(#opts{packet = 4})    -> <<4:8>>;
setopts_packet_mode(#opts{packet = line}) -> <<5:8>>.

%% @doc Encode maximum allowed packet size.

-spec setopts_packet_size(Opts :: #opts{}) ->
  binary().

setopts_packet_size(#opts{packet_size = undefined}) -> <<0:32>>;
setopts_packet_size(#opts{packet_size = Size}) -> <<Size:32>>.

%% }}}
%%----------------------------------------------------------

%% @doc Read options and PID from port.

-spec ioctl_getopts(subproc:handle()) ->
  #opts{}.

ioctl_getopts(Port) ->
  <<ReadMode:8, DataMode:8, PacketMode:8, PacketSize:32, PID:32>> =
    port_control(Port, 2, <<>>),
  _Result = #opts{
    mode = getopts_data_mode(DataMode),
    active = getopts_read_mode(ReadMode),
    %exit_status = getopts_exit_status_mode(ExitStatusMode), % TODO
    packet = getopts_packet_mode(PacketMode),
    packet_size = PacketSize,
    pid = getopts_pid(PID)
  }.

%%----------------------------------------------------------
%% getopts data formatters {{{

%% @doc Decode read mode (`{active,_}').

-spec getopts_read_mode(V :: integer()) ->
  true | false | once.

getopts_read_mode(1) -> false;
getopts_read_mode(2) -> true;
getopts_read_mode(3) -> once.

%% @doc Decode exit status mode (`{exit_status,_}').

-spec getopts_exit_status_mode(V :: integer()) ->
  true | false.

getopts_exit_status_mode(1) -> false;
getopts_exit_status_mode(2) -> true.

%% @doc Decode type of data returned from reads.

-spec getopts_data_mode(V :: integer()) ->
  list | binary.

getopts_data_mode(1) -> list;
getopts_data_mode(2) -> binary.

%% @doc Decode packet decoding mode.

-spec getopts_packet_mode(V :: integer()) ->
  raw | 1 | 2 | 4 | line.

getopts_packet_mode(1) -> raw;
getopts_packet_mode(2) -> 1;
getopts_packet_mode(3) -> 2;
getopts_packet_mode(4) -> 4;
getopts_packet_mode(5) -> line.

%% @doc Decode PID.

-spec getopts_pid(V :: integer()) ->
  subproc:os_pid() | undefined.

getopts_pid(0) -> undefined;
getopts_pid(PID) -> PID.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% parsing options
%%%---------------------------------------------------------------------------

%% @doc Check if the list of options is valid.

-spec valid_options([subproc:read_option() | open_option()]) ->
  boolean().

valid_options(Options) ->
  case options(Options, #opts{}) of
    {ok, _} -> true;
    {error, _} -> false
  end.

%% @doc Convert a list of options to a usable structure.

-spec options([subproc:read_option() | open_option()], #opts{}) ->
  {ok, #opts{}} | {error, badarg}.

options(Options, Defaults) ->
  try lists:foldr(fun option/2, Defaults, Options) of
    Opts -> {ok, Opts}
  catch
    _:_ -> {error, badarg}
  end.

%% @doc Fold workhorse for {@link options/2}.

-spec option(subproc:read_option() | open_option(), #opts{}) ->
  #opts{}.

option(Mode, Opts) when Mode == list; Mode == binary ->
  Opts#opts{mode = Mode};
option({mode, Mode}, Opts) when Mode == list; Mode == binary ->
  Opts#opts{mode = Mode};
option({active, Mode}, Opts) when Mode == true; Mode == false; Mode == once ->
  Opts#opts{active = Mode};
option({exit_status, Mode}, Opts) when is_boolean(Mode) ->
  Opts#opts{exit_status = Mode};
option({packet, P}, Opts) when P == 0; P == raw ->
  Opts#opts{packet = raw};
option({packet, P}, Opts) when P == 1; P == 2; P == 4; P == line ->
  Opts#opts{packet = P};
option({packet_size, Size}, Opts)
when is_integer(Size), Size > 0, Size =< ?MAX_UINT ->
  Opts#opts{packet_size = Size};
option({close, AutoClose}, Opts) when is_boolean(AutoClose) ->
  Opts#opts{close = AutoClose};
option({close_on_exit, CloseOnExit}, Opts) when is_boolean(CloseOnExit) ->
  Opts#opts{close_on_exit = CloseOnExit};
option({pid, PID}, Opts) when is_integer(PID), PID > 0, PID =< ?MAX_SINT ->
  Opts#opts{pid = PID}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
