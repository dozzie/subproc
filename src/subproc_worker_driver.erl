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
-export([setopts/2, getopts/2, controlling_process/2]).
-export([valid_options/1]).
-export([format_error/1]).

-export_type([handle/0, option/0, option_name/0, message/0]).

%%%---------------------------------------------------------------------------
%%% types

%% for port driver
-define(DRIVER_NAME, "subproc_drv").

-define(MAX_SINT, 16#7fffffff).
-define(MAX_UINT, 16#ffffffff).

-type handle() :: port().

-type option_name() :: mode | active | packet | packet_size.

-type option() :: list | binary | {mode, list | binary}
                | {active, true | false | once}
                | {packet, 0 | 1 | 2 | 4 | raw | line}
                | {packet_size, pos_integer()}.
%% `{packet,raw}' and `{packet,0}' are synonymous, with `raw' being the
%% canonical value.

-type message() :: {subproc, Port :: handle(), Data :: binary() | list()}
                 | {subproc_closed, Port :: handle()}
                 | {subproc_error, Port :: handle(), Reason :: term()}
                 | {subproc_exit, Port :: handle(), subproc_unix:exit_code()}
                 | {subproc_signal, Port :: handle(),
                     {subproc_unix:signal_number(),
                      subproc_unix:signal_name()}}.

-type posix() :: inet:posix().

-record(opts, {
  mode :: list | binary | undefined,
  active :: true | false | once | undefined,
  packet :: raw | 1 | 2 | 4 | line | undefined,
  packet_size :: pos_integer() | undefined,
  pid :: subproc_unix:os_pid() | undefined
}).

%%%---------------------------------------------------------------------------
%%% opening and closing the port
%%%---------------------------------------------------------------------------

%% @doc Open a port for reading/writing to/from subprocess.

-spec open(STDIO, [option() | {pid, subproc_unix:os_pid()}]) ->
  {ok, handle()} | {error, badarg | system_limit | posix()}
  when STDIO :: {bidir, FDRW} | {in, FDR} | {out, FDW} | {in_out, {FDR, FDW}},
       FDRW :: subproc_unix:os_fd(),
       FDR :: subproc_unix:os_fd(),
       FDW :: subproc_unix:os_fd().

open(STDIO, Options) ->
  Defaults = #opts{
    mode = list,
    active = false,
    packet = raw,
    packet_size = 16384 % 16kB
  },
  case {valid_stdio(STDIO), options(Options, Defaults)} of
    {true, {ok, Opts = #opts{pid = PID}} } ->
      PrivDir = elf_library_dir(),
      ok = erl_ddll:load(PrivDir, ?DRIVER_NAME),
      try open_port({spawn_driver, ?DRIVER_NAME}, [binary]) of
        Port ->
          ok = ioctl_setfd(Port, STDIO, PID),
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

-spec close(handle()) ->
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

-spec close(handle(), read | write | read_write) ->
  ok.

close(_Port, read = _How) ->
  'TODO';
close(_Port, write = _How) ->
  'TODO';
close(_Port, read_write = _How) ->
  'TODO'.

%%%---------------------------------------------------------------------------
%%% input/output
%%%---------------------------------------------------------------------------

%% @doc Send data to the subprocess.
%%
%% @todo Return value

-spec send(handle(), iolist()) ->
  ok.

send(_Port, _Data) ->
  'TODO'.

%% @doc Read data from the subprocess.
%%
%% @todo Return value

-spec recv(handle(), non_neg_integer()) ->
  ok.

recv(Port, Length) ->
  recv(Port, Length, infinity).

%% @doc Read data from the subprocess.
%%
%% @todo Return value

-spec recv(handle(), non_neg_integer(), timeout()) ->
  ok.

recv(_Port, _Length, _Timeout) ->
  %case port_control(Port, {active, once}) of
  %  {ok, OldMode} ->
  %    receive
  %      message() -> ...
  %    after Timeout ->
  %      port_control(Port, OldMode),
  %      % flush a possible pending message
  %      receive
  %        message() -> ...
  %      after 0 ->
  %        {error, timeout}
  %      end
  %    end;
  %  {error, active} ->
  %    {error, einval}; % that's what gen_tcp returns on active sockets
  %  {error, closed} ->
  %    {error, closed}
  %end.
  'TODO'.

%%%---------------------------------------------------------------------------
%%% options
%%%---------------------------------------------------------------------------

%% @doc Set one or more options for a port.

-spec setopts(handle(), [option()]) ->
  ok | {error, badarg}.

setopts(Port, Options) ->
  case options(Options, #opts{}) of
    {ok, Opts = #opts{pid = undefined}} ->
      % try..catch to match `getopts()' behaviour on invalid port
      try
        ok = ioctl_setopts(Port, Opts)
      catch
        _:_ -> {error, badarg}
      end;
    {ok, _Opts = #opts{pid = PID}} when PID /= undefined ->
      {error, badarg};
    {error, badarg} ->
      {error, badarg}
  end.

%% @doc Get one or more options for a port.

-spec getopts(handle(), [option_name() | pid]) ->
  {ok, [option() | {pid, PID}]} | {error, badarg}
  when PID :: subproc_unix:os_pid() | undefined.

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
  when Option :: option() | {pid, subproc_unix:os_pid() | undefined}.

get_option(mode = Name, {OptList, Opts = #opts{mode = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(active = Name, {OptList, Opts = #opts{active = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(packet = Name, {OptList, Opts = #opts{packet = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(packet_size = Name, {OptList, Opts = #opts{packet_size = Value}}) ->
  {[{Name, Value} | OptList], Opts};
get_option(pid = Name, {OptList, Opts = #opts{pid = Value}}) ->
  {[{Name, Value} | OptList], Opts}.

%% @doc Assign a new owner to a port.

-spec controlling_process(handle(), pid()) ->
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

format_error(_) ->
  "TODO".

%%%---------------------------------------------------------------------------
%%% port ioctl
%%%---------------------------------------------------------------------------

%% @doc Initialize the port with file handles.
%%
%%   Reinitializing a port is not possible and causes `error:badarg' crash.

-spec ioctl_setfd(handle(), tuple(), subproc_unix:os_pid() | undefined) ->
  ok.

ioctl_setfd(Port, STDIO, PID) ->
  STDIOPart = case STDIO of
    {bidir, FDRW} -> <<FDRW:32, FDRW:32>>;
    {in,  FDR} -> <<FDR:32, (-1):32>>;
    {out, FDW} -> <<(-1):32, FDW:32>>;
    {in_out, {FDR, FDW}} -> <<FDR:32, FDW:32>>
  end,
  PIDPart = case PID of
    undefined -> <<0:32>>;
    _ when is_integer(PID) -> <<PID:32>>
  end,
  port_control(Port, 0, [STDIOPart, PIDPart]),
  ok.

%% @doc Set port options.
%%
%%   PID, even if defined, is ignored, as it's only allowed to be set with
%%   {@link ioctl_setfd/3}.

-spec ioctl_setopts(handle(), #opts{}) ->
  ok.

ioctl_setopts(Port, Options) ->
  port_control(Port, 1, [
    setopts_read_mode(Options),
    setopts_data_mode(Options),
    setopts_packet_mode(Options),
    setopts_buffer_size(Options)
  ]),
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

%% @doc Encode buffer size (maximum allowed packet).

-spec setopts_buffer_size(Opts :: #opts{}) ->
  binary().

setopts_buffer_size(#opts{packet_size = undefined}) -> <<0:32>>;
setopts_buffer_size(#opts{packet_size = Size}) -> <<Size:32>>.

%% }}}
%%----------------------------------------------------------

%% @doc Read options and PID from port.

-spec ioctl_getopts(handle()) ->
  #opts{}.

ioctl_getopts(Port) ->
  <<ReadMode:8, DataMode:8, PacketMode:8, BufSize:32, PID:32>> =
    port_control(Port, 2, <<>>),
  _Result = #opts{
    mode = getopts_data_mode(DataMode),
    active = getopts_read_mode(ReadMode),
    packet = getopts_packet_mode(PacketMode),
    packet_size = BufSize,
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
  subproc_unix:os_pid() | undefined.

getopts_pid(0) -> undefined;
getopts_pid(PID) -> PID.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% parsing options
%%%---------------------------------------------------------------------------

%% @doc Check if the list of options is valid.

-spec valid_options([option() | {pid, subproc_unix:os_pid()}]) ->
  boolean().

valid_options(Options) ->
  case options(Options, #opts{}) of
    {ok, _} -> true;
    {error, _} -> false
  end.

%% @doc Convert a list of options to a usable structure.

-spec options([option() | {pid, subproc_unix:os_pid()}], #opts{}) ->
  {ok, #opts{}} | {error, badarg}.

options(Options, Defaults) ->
  try lists:foldr(fun option/2, Defaults, Options) of
    Opts -> {ok, Opts}
  catch
    _:_ -> {error, badarg}
  end.

%% @doc Fold workhorse for {@link options/2}.

-spec option(option() | {pid, subproc_unix:os_pid()}, #opts{}) ->
  #opts{}.

option(Mode, Opts) when Mode == list; Mode == binary ->
  Opts#opts{mode = Mode};
option({mode, Mode}, Opts) when Mode == list; Mode == binary ->
  Opts#opts{mode = Mode};
option({active, Mode}, Opts) when Mode == true; Mode == false; Mode == once ->
  Opts#opts{active = Mode};
option({packet, P}, Opts) when P == 0; P == raw ->
  Opts#opts{packet = raw};
option({packet, P}, Opts) when P == 1; P == 2; P == 4; P == line ->
  Opts#opts{packet = P};
option({packet_size, Size}, Opts)
when is_integer(Size), Size > 0, Size =< ?MAX_UINT ->
  Opts#opts{packet_size = Size};
option({pid, PID}, Opts) when is_integer(PID), PID > 0, PID =< ?MAX_SINT ->
  Opts#opts{pid = PID}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
