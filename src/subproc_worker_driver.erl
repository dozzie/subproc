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
-export([format_error/1]).

-export_type([handle/0, option/0, option_name/0, message/0]).

%%%---------------------------------------------------------------------------
%%% types

%% for port driver
-define(DRIVER_NAME, "subproc_drv").

-type handle() :: port().

-type option_name() :: mode | active | packet | packet_size.

-type option() :: list | binary | {mode, list | binary}
                | {active, true | false | once}
                | {packet, 0 | 1 | 2 | 4 | raw | line}
                | {packet_size, pos_integer()}.

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
  {ok, handle()} | {error, badarg | no_packet}
  when STDIO :: {bidir, FDRW} | {in, FDR} | {out, FDW} | {in_out, {FDR, FDW}},
       FDRW :: subproc_unix:os_fd(),
       FDR :: subproc_unix:os_fd(),
       FDW :: subproc_unix:os_fd().

open(_STDIO, Options) ->
  Defaults = #opts{
    mode = list,
    active = false,
    packet = raw,
    packet_size = 16384 % 16kB
  },
  case options(Options, Defaults) of
    {error, Reason} ->
      {error, Reason};
    {ok, _Opts} ->
      PrivDir = elf_library_dir(),
      ok = erl_ddll:load(PrivDir, ?DRIVER_NAME),
      try open_port({spawn_driver, ?DRIVER_NAME}, [binary]) of
        Port ->
          % TODO: set descriptors, PID, and options
          {ok, Port}
      catch
        error:Reason ->
          erl_ddll:unload(?DRIVER_NAME),
          {error, Reason}
      end
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

setopts(_Port, Options) ->
  case options(Options, #opts{}) of
    {ok, _Opts = #opts{pid = undefined}} ->
      'TODO';
    {ok, _Opts = #opts{pid = PID}} when PID /= undefined ->
      {error, badarg};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Get one or more options for a port.

-spec getopts(handle(), [option_name()]) ->
  {ok, [option()]} | {error, badarg}.

getopts(_Port, _Options) ->
  'TODO'.

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
%%% parsing options
%%%---------------------------------------------------------------------------

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
when is_integer(Size), Size > 0, Size =< 16#ffffffff ->
  Opts#opts{packet_size = Size};
option({pid, PID}, Opts) when is_integer(PID), PID > 0, PID =< 16#ffffffff ->
  Opts#opts{pid = PID}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
