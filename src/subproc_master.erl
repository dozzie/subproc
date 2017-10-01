%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Owner of master port driver and OS process operation gateway.
%%%
%%%   The process starts `subproc''s master port driver (and thus OS process
%%%   for spawning further subprocesses). It also acts as a gateway for
%%%   spawn and kill requests, distributes <i>exit</i> and <i>signal</i>
%%%   events to spawned worker ports, and sends kill requests on worker port
%%%   termination.
%%%
%%% @see subproc_mdrv_reaper
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_master).

-behaviour(gen_server).

%% public interface
-export([exec/3, open/2, kill/2]).
-export([reload/0]).
-export([format_error/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-record(state, {
  port :: subproc_master_driver:handle(),
  registry :: ets:tab() % port => ID, ID => port
}).

-record(opts, {
  port_type = subproc :: subproc | native | raw_fd,
  close = true :: boolean(),          % `{close, _}'
  close_on_exit = true :: boolean(),  % `{close_on_exit, _}'
  active = false :: true | false | once, % `{active, _}'
  exit_status = false :: true | false,   % `{exit_status, _}'
  exec_options = [] :: [term()],
  port_options = [] :: [term()]
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start subprocess master process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start subprocess master process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Execute a command as a subprocess under unix supervisor.

-spec exec(file:filename(), [string()], Options :: [Option]) ->
    {ok, port() | RawInfo}
  | {error, bad_owner | badarg | system_limit | ExecError | RequestError}
  when Option :: subproc:exec_option() | subproc:port_option()
               | subproc:read_option() | subproc:native_read_option(),
       RawInfo :: {ID :: subproc_master_driver:subproc_id(),
                    PID :: subproc:os_pid(), STDIO :: subproc:stdio()},
       ExecError :: {Stage :: atom(), Error :: subproc:posix()},
       RequestError :: atom().

exec(Command, Args, Options) ->
  case call({exec, self(), Command, Args, Options}) of
    {ok, Port} when is_port(Port) ->
      {ok, Port};
    {ok, {native, ID, {in_out, {FDR, FDW}}, PortOpts, AutoClose}} ->
      try open_port({fd, FDR, FDW}, PortOpts) of
        Port when AutoClose ->
          % register port for killing and FDs closing
          ok = call({reg, Port, native, ID, [FDR, FDW]}),
          {ok, Port};
        Port when not AutoClose ->
          % register port for killing
          ok = call({reg, Port, native, ID, []}),
          {ok, Port}
      catch
        error:Reason ->
          call({open_port_failed, ID}),
          subproc_unix:close(FDR),
          subproc_unix:close(FDW),
          {error, Reason}
      end;
    {ok, {raw_fd, ID, PID, STDIO}} ->
      {ok, {ID, PID, STDIO}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Open a port from raw file descriptors.
%%
%%   In case of an error, the caller is responsible for closing the
%%   descriptors.

-spec open(STDIO :: subproc:stdio(), Options :: [Option]) ->
  {ok, port() | subproc:stdio()} | {error, badarg | system_limit}
  when Option :: subproc:exec_option() | subproc:port_option()
               | subproc:read_option() | subproc:native_read_option().

open(STDIO, Options) ->
  case {STDIO, options(Options)} of
    {_, #opts{port_type = raw_fd}} ->
      {ok, STDIO};
    {{in_out, {FDR, FDW}},
      #opts{port_type = native, port_options = Opts, close = AutoClose}} ->
      try open_port({fd, FDR, FDW}, Opts) of
        Port when AutoClose ->
          ok = call({reg, Port, native, undefined, [FDR, FDW]}),
          {ok, Port};
        Port when not AutoClose ->
          % nothing to kill, nothing to close, no need to watch the port
          {ok, Port}
      catch
        error:Reason ->
          {error, Reason}
      end;
    {_, #opts{port_type = native, close = _AutoClose}} ->
      {error, badarg};
    {_, #opts{port_type = subproc, port_options = Opts, close = AutoClose}} ->
      case subproc_worker_driver:open(STDIO, [{close, AutoClose} | Opts]) of
        {ok, Port} ->
          % nothing to kill, nothing to close (the port closes the descriptors
          % on its own), no need to watch the port
          {ok, Port};
        {error, Reason} ->
          {error, Reason}
      end;
    {_, {error, badarg}} ->
      {error, badarg}
  end.

%% @doc Kill a child process running under unix supervisor.
%%
%%   If the child already terminated or the port was not spawned with
%%   {@link exec/3} or {@link open/2}, `{error, badarg}' is returned.

-spec kill(port(), default | subproc:signal()) ->
  ok | {error, badarg | bad_signal | subproc:posix()}.

kill(Port, Signal) ->
  case call({kill, Port, Signal}) of
    ok -> ok;
    {error, nxchild} -> {error, badarg};
    {error, Reason} -> {error, Reason}
  end.

%% @doc Reload shutdown options from application's environment.

-spec reload() ->
  ok | {error, badarg}.

reload() ->
  call(reload).

%% @doc Format a reason from error tuple as a usable error message.

-spec format_error(term()) ->
  string().

format_error(Reason) ->
  subproc_master_driver:format_error(Reason).

%%----------------------------------------------------------
%% call() {{{

%% @doc Call `subproc_master' process.

-spec call(term()) ->
  term().

call(Request) ->
  gen_server:call(?MODULE, Request, infinity).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init(_Args) ->
  process_flag(trap_exit, true),
  MasterOptions = case shutdown_options() of
    {ok, {Timeout, true = _KillFlag}} ->
      [{shutdown_timeout, Timeout}, shutdown_kill];
    {ok, {Timeout, false = _KillFlag}} ->
      [{shutdown_timeout, Timeout}, no_shutdown_kill]
  end,
  {ok, MasterPort} = subproc_master_driver:open(MasterOptions),
  subproc_mdrv_reaper:watch(MasterPort),
  Registry = ets:new(subproc_port_registry, [set, protected]),
  State = #state{
    port = MasterPort,
    registry = Registry
  },
  {ok, State}.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(Reason, _State = #state{port = undefined, registry = Registry}) ->
  % XXX: can't kill subprocesses, because master died
  % kill the registered ports and close their autoclose descriptors
  port_foreach(
    fun(Port, _, _, FDs) -> shutdown_port(Port, {master_died,Reason}, FDs) end,
    Registry
  ),
  ets:delete(Registry),
  ok;
terminate(_Arg, _State = #state{port = MasterPort, registry = Registry}) ->
  % order the subprocess supervisor to kill all children and terminate
  subproc_master_driver:shutdown(MasterPort),
  % read all events, closing file descriptors marked as "close on exit"
  shutdown_collect_events(MasterPort, Registry),
  % kill the remaining registered ports and close their autoclose descriptors
  port_foreach(
    fun(Port, _, _, FDs) -> shutdown_port(Port, shutdown, FDs) end,
    Registry
  ),
  ets:delete(Registry),
  ok.

%% @doc Handle all events from subprocess supervisor.
%%
%%   All events up until shutdown event or port exit are received. Exit info
%%   for `subproc'-type ports is forwarded as usual (those ports are
%%   unregistered). If a port during this phase terminates, its descriptors
%%   are automatically closed as well.

-spec shutdown_collect_events(port(), ets:tab()) ->
  term().

shutdown_collect_events(MasterPort, Registry) ->
  receive
    {subproc_sup, MasterPort, EventData, FDs} = Message ->
      case process_event(Message, Registry) of
        processed ->
          shutdown_collect_events(MasterPort, Registry);
        {shutdown, 0 = _AliveChildren} ->
          subproc_master_driver:close(MasterPort);
        {shutdown, AliveChildren} when AliveChildren > 0 ->
          error_logger:warning_report(subproc_master, [
            "shutdown incomplete",
            {alive_children, AliveChildren}
          ]),
          subproc_master_driver:close(MasterPort);
        {error, unknown_event} ->
          error_logger:warning_report(subproc_master, [
            "unrecognized event from subprocess supervisor",
            {event_data, EventData},
            {fds, FDs}
          ]),
          shutdown_collect_events(MasterPort, Registry)
      end;
    {'EXIT', MasterPort, Reason} ->
      error_logger:warning_report(subproc_master, [
        "early exit from supervisor port",
        {exit, Reason}
      ]),
      subproc_master_driver:close(MasterPort);
    {'EXIT', Port, _Reason} ->
      port_autoclose(Port, Registry),
      shutdown_collect_events(MasterPort, Registry)
  end.

%% @doc Send a signal to a port and close its file descriptors recorded for
%%   autoclosing.

-spec shutdown_port(port(), term(), [subproc:os_fd()]) ->
  term().

shutdown_port(Port, Reason, CloseFDs) ->
  try
    exit(Port, Reason),
    receive {'EXIT', Port, _} -> ok end
  catch % exit() could fail on already closed port
    _:_ -> ignore
  end,
  lists:foreach(fun subproc_unix:close/1, CloseFDs).

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({exec, Owner, Command, Args, OptionList} = _Request, _From,
            State = #state{port = MasterPort, registry = Registry}) ->
  % FIXME: We parse one of the option lists (after splitting) twice, once for
  % checking for validity (for native port, `subproc_master_driver' options
  % for STDIO mode; for subproc port, `subproc_worker_driver' options for full
  % verification), and second time for actual work. The modules could provide
  % a way to compile the options and pass them prepared. Hopefully, the option
  % lists are short.
  case options(OptionList) of
    Opts = #opts{} ->
      case spawn_port(MasterPort, Command, Args, Opts) of
        {subproc, Port, ID, PortOpts} ->
          try subproc_worker_driver:controlling_process(Port, Owner) of
            _ when PortOpts /= [] ->
              % options to set after owner change (e.g. `{active,true}')
              subproc_worker_driver:setopts(Port, PortOpts),
              true = port_register(Port, ID, Registry),
              {reply, {ok, Port}, State};
            _ ->
              true = port_register(Port, ID, Registry),
              {reply, {ok, Port}, State}
          catch
            _:_ ->
              subproc_master_driver:kill(MasterPort, ID),
              subproc_worker_driver:close(Port),
              {reply, {error, bad_owner}, State}
          end;
        {native, PortStub} ->
          {reply, {ok, PortStub}, State};
        {raw_fd, PortStub} ->
          {reply, {ok, PortStub}, State};
        {error, Reason} ->
          {reply, {error, Reason}, State}
      end;
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;

handle_call({reg, Port, PortType, ID, CloseFDs} = _Request, _From,
            State = #state{registry = Registry}) ->
  % NOTE: only native ports need registering this way
  case port_register(Port, ID, PortType, CloseFDs, Registry) of
    true -> {reply, ok, State};
    false -> {reply, {error, badarg}, State}
  end;

handle_call({open_port_failed, ID} = _Request, _From,
            State = #state{port = MasterPort}) ->
  Reply = subproc_master_driver:kill(MasterPort, ID, default),
  {reply, Reply, State};

handle_call({kill, What, Signal} = _Request, _From,
            State = #state{port = MasterPort, registry = Registry}) ->
  case port_find_id(What, Registry) of
    {ok, ID} ->
      Reply = subproc_master_driver:kill(MasterPort, ID, Signal),
      {reply, Reply, State};
    undefined ->
      {reply, {error, badarg}, State}
  end;

handle_call(reload = _Request, _From, State = #state{port = MasterPort}) ->
  Result = case shutdown_options() of
    {ok, {Timeout, KillFlag}} ->
      subproc_master_driver:shutdown_options(MasterPort, Timeout, KillFlag);
    {error, badarg} ->
      {error, badarg}
  end,
  {reply, Result, State};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({subproc_sup, MasterPort, EventData, FDs} = Message,
            State = #state{port = MasterPort, registry = Registry}) ->
  case process_event(Message, Registry) of
    processed ->
      {noreply, State};
    {shutdown, 0 = AliveChildren} ->
      subproc_master_driver:close(MasterPort),
      error_logger:warning_report(subproc_master, [
        "unexpected shutdown",
        {alive_children, AliveChildren}
      ]),
      NewState = State#state{port = undefined},
      {stop, normal, NewState};
    {shutdown, AliveChildren} when AliveChildren > 0 ->
      subproc_master_driver:close(MasterPort),
      error_logger:warning_report(subproc_master, [
        "unexpected shutdown incomplete",
        {alive_children, AliveChildren}
      ]),
      subproc_master_driver:close(MasterPort),
      NewState = State#state{port = undefined},
      {stop, normal, NewState};
    {error, unknown_event} ->
      error_logger:warning_report(subproc_master, [
        "unrecognized event from subprocess supervisor",
        {event_data, EventData},
        {fds, FDs}
      ]),
      {noreply, State}
  end;

handle_info({'EXIT', MasterPort, Reason} = _Message,
            State = #state{port = MasterPort}) ->
  subproc_master_driver:close(MasterPort),
  NewState = State#state{port = undefined},
  {stop, Reason, NewState};

handle_info({'EXIT', Port, _Reason} = _Message,
            State = #state{port = MasterPort, registry = Registry}) ->
  case port_autoclose(Port, Registry) of
    undefined -> ignore;
    ID -> subproc_master_driver:kill(MasterPort, ID, default)
  end,
  {noreply, State};

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State}.

%% }}}
%%----------------------------------------------------------
%% code change {{{

%% @private
%% @doc Handle code change.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

%% @doc Spawn a port according to provided options.

-spec spawn_port(subproc_master_driver:handle(), file:filename(), [string()],
                 Opts :: #opts{}) ->
    {subproc, subproc:handle(), subproc_master_driver:subproc_id()}
  | {native, NativePortStub :: tuple()}
  | {raw_fd, RawFDPortStub :: tuple()}
  | {error, ExecError | WorkerError}
  when ExecError :: term(),
       WorkerError :: badarg.

spawn_port(MasterPort, Command, Args,
           #opts{port_type = PortType, exec_options = ExecOpts,
                 port_options = PortOpts, close = AutoClose,
                 close_on_exit = CloseOnExit,
                 active = Active, exit_status = ExitStatus}) ->
  case subproc_master_driver:exec(MasterPort, Command, Args, ExecOpts) of
    {ok, {ID, PID, STDIO}} when PortType == subproc ->
      OpenOptions = [
        {active, false},      % these messages are intended for the new owner,
        {exit_status, false}, % so we want to avoid race conditions
        {pid, PID},
        {close, AutoClose},
        {close_on_exit, CloseOnExit} |
        PortOpts
      ],
      case subproc_worker_driver:open(STDIO, OpenOptions) of
        {ok, Port} when not Active, not ExitStatus ->
          {subproc, Port, ID, []};
        {ok, Port} ->
          {subproc, Port, ID, [{active, Active}, {exit_status, ExitStatus}]};
        {error, Reason} ->
          close_stdio(STDIO),
          {error, Reason}
      end;
    {ok, {ID, _PID, STDIO}} when PortType == native ->
      PortStub = {native, ID, STDIO, PortOpts, AutoClose},
      {native, PortStub};
    {ok, {ID, PID, STDIO}} when PortType == raw_fd ->
      PortStub = {raw_fd, ID, PID, STDIO},
      {raw_fd, PortStub};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Close subprocess' STDIO.

close_stdio({bidir, FDRW} = _STDIO) ->
  subproc_unix:close(FDRW);
close_stdio({in, FDR} = _STDIO) ->
  subproc_unix:close(FDR);
close_stdio({out, FDW} = _STDIO) ->
  subproc_unix:close(FDW);
close_stdio({in_out, {FDR, FDW}} = _STDIO) ->
  subproc_unix:close(FDR),
  subproc_unix:close(FDW).

%%%---------------------------------------------------------------------------

%% @doc Process an event coming from subprocess supervisor.
%%
%%   `subproc'-type ports are unregistered and informed that their subprocess
%%   terminated.

-spec process_event(subproc_master_driver:event_message(), ets:tab()) ->
  processed | {shutdown, non_neg_integer()} | {error, unknown_event}.

process_event(Message, Registry) ->
  % NOTE: `exec' and `exec_error' messages can only arrive on exec request,
  % and we don't have such requests running asynchronously
  case subproc_master_driver:decode_event(Message) of
    {TermType, ID, TermData} when TermType == exit; TermType == signal ->
      % subprocess terminated; `TermData' interpretation:
      %   `TermType = exit': `ExitCode'
      %   `TermType = signal': `{SigNum, SigName}'
      case port_unregister(ID, Registry) of
        {ok, subproc, Port} ->
          subproc_worker_driver:terminated(Port, {TermType, TermData});
        {ok, native, _Port} ->
          ignore;
        none ->
          ignore
      end,
      processed;
    {shutdown, AliveChildren} ->
      {shutdown, AliveChildren};
    {error, unknown_event} ->
      {error, unknown_event}
  end.

%%%---------------------------------------------------------------------------

%% @doc Split options into categories.
%%
%%   The categories are: exec options for unix subproc supervisor, port
%%   creation options (type and FD autoclosing for native port), and port's
%%   own options.

-spec options([term()]) ->
  #opts{} | {error, badarg}.

options(Options) ->
  try lists:foldr(fun option/2, #opts{}, Options) of
    Opts = #opts{port_type = subproc, port_options = PortOpts} ->
      % don't execute a command if it's known to fail at port creation
      case subproc_worker_driver:valid_options(PortOpts) of
        true -> Opts;
        false -> {error, badarg}
      end;
    Opts = #opts{port_type = native, exec_options = ExecOpts} ->
      % Erlang's built-in port requires two separate descriptors
      % XXX: I'd be glad to validate port options here, but there's no
      % "dry-run" mode
      case subproc_master_driver:stdio_mode(ExecOpts) of
        in_out -> Opts;
        _ -> {error, badarg}
      end;
    Opts = #opts{port_type = raw_fd, port_options = []} ->
      Opts;
    _Opts = #opts{port_type = raw_fd, port_options = [_|_]} ->
      % port options are not allowed when raw FDs are returned
      {error, badarg}
  catch
    throw:{error, Reason} ->
      {error, Reason}
  end.

%% @doc Fold workhorse for {@link options/1}.

-spec option(Option :: term(), #opts{}) ->
  #opts{}.

option(subproc, Opts) -> Opts#opts{port_type = subproc};
option(native,  Opts) -> Opts#opts{port_type = native};
option(raw_fd,  Opts) -> Opts#opts{port_type = raw_fd};
%% NOTE: `{close,_}' and `{close_on_exit,_}' are intercepted here, unlike
%% other options necessary for opening a port, because for native ports they
%% are handled from the outside of the spawned port
option({close, true},  Opts) -> Opts#opts{close = true};
option({close, false}, Opts) -> Opts#opts{close = false};
option({close, _}, _Opts) -> erlang:throw({error, badarg});
option({close_on_exit, true},  Opts) -> Opts#opts{close_on_exit = true};
option({close_on_exit, false}, Opts) -> Opts#opts{close_on_exit = false};
option({close_on_exit, _}, _Opts) -> erlang:throw({error, badarg});
%% `{active,_}' and `{exit_status,_}' are port options, not exec options, so
%% we can decide here, and we need to know their values now, so the process
%% requesting a subproc-type port sets them later (port is opened in passive
%% mode)
option({active, Value} = Option, Opts = #opts{port_options = POpts}) ->
  Opts#opts{active = Value, port_options = [Option | POpts]};
option({exit_status, Value} = Option, Opts = #opts{port_options = POpts}) ->
  Opts#opts{exit_status = Value, port_options = [Option | POpts]};
option(Option, Opts = #opts{exec_options = EOpts, port_options = POpts}) ->
  case subproc_master_driver:is_option(Option) of
    true  -> Opts#opts{exec_options = [Option | EOpts]};
    false -> Opts#opts{port_options = [Option | POpts]}
  end.

%%%---------------------------------------------------------------------------
%%% port registry

%% @doc Register `subproc'-type port for watching.

-spec port_register(port(), subproc_master_driver:subproc_id() | undefined,
                    ets:tab()) ->
  boolean().

port_register(Port, ID, Registry) ->
  % FDs are an empty list, since the port can close them on its own
  port_register(Port, ID, subproc, [], Registry).

%% @doc Register a port for watching.

-spec port_register(port(), subproc_master_driver:subproc_id() | undefined,
                    subproc | native, [subproc:os_fd()], ets:tab()) ->
  boolean().

port_register(Port, ID, PortType, FDs, Registry)
when is_port(Port), is_list(FDs) ->
  try link(Port) of
    _ ->
      Records = case ID of
        undefined -> [{Port, ID, PortType, FDs}];
        _ when is_integer(ID) -> [{Port, ID, PortType, FDs}, {ID, Port}]
      end,
      ets:insert_new(Registry, Records)
  catch
    _:_ -> false
  end.

%% @doc Find subprocess ID for specified key.

-spec port_find_id(port() | subproc_master_driver:subproc_id(), ets:tab()) ->
  {ok, subproc_master_driver:subproc_id()} | undefined.

port_find_id(Key, Registry) ->
  case ets:lookup(Registry, Key) of
    [{_Port, undefined = _ID, _PortType, _CloseFDs}] -> undefined;
    [{_Port, ID, _PortType, _CloseFDs}] -> {ok, ID};
    [{ID, _Port}] -> {ok, ID};
    [] -> undefined
  end.

%% @doc Unregister a port whose subprocess terminated.

-spec port_unregister(subproc_master_driver:subproc_id(), ets:tab()) ->
  {ok, subproc | native, port()} | none.

%port_unregister(ID, _Registry) when not is_integer(ID) ->
%  none;
port_unregister(ID, Registry) when is_integer(ID) ->
  case ets:lookup(Registry, ID) of
    [{ID, Port}] ->
      case ets:lookup(Registry, Port) of
        [{Port, ID, subproc, _FDs}] ->
          try
            unlink(Port)
          catch
            _:_ -> ignore
          end,
          ets:delete(Registry, ID),
          ets:delete(Registry, Port),
          {ok, subproc, Port};
        [{Port, ID, native, _FDs}] ->
          % XXX: don't unlink and keep the descriptors record, so autoclose
          % works
          {ok, native, Port}
      end;
    [] ->
      none
  end.

%% @doc Close descriptors recorded for autoclose on port termination.
%%
%%   Function deletes the port from the registry.

-spec port_autoclose(port(), ets:tab()) ->
  subproc_master_driver:subproc_id() | undefined.

port_autoclose(Port, Registry) ->
  case ets:lookup(Registry, Port) of
    [{Port, ID, _PortType, CloseFDs}] ->
      % port that wasn't associated with any subprocess
      lists:foreach(fun subproc_unix:close/1, CloseFDs),
      ets:delete(Registry, ID), % safe even for `ID = undefined'
      ets:delete(Registry, Port),
      ID;
    [] ->
      undefined
  end.

%% @doc Call a function on each port

-spec port_foreach(Fun, ets:tab()) ->
  ok
  when Fun :: fun((Port, ID, PortType, CloseFDs) -> term()),
       Port :: port(),
       ID :: subproc_master_driver:subproc_id(),
       PortType :: subproc | native,
       CloseFDs :: [subproc:os_fd()].

port_foreach(Fun, Registry) when is_function(Fun, 4) ->
  ets:foldl(fun each_port/2, Fun, Registry),
  ok.

%% @doc Workhorse for {@link port_foreach/2}.

-spec each_port(tuple(), fun()) ->
  fun().

each_port({Port, ID, PortType, FDs} = _Entry, Fun) ->
  Fun(Port, ID, PortType, FDs),
  Fun;
each_port({_ID, _Port} = _Entry, Fun) ->
  Fun.

%%%---------------------------------------------------------------------------

%% @doc Get subprocess' supervisor shutdown options from application
%%   environment.

-spec shutdown_options() ->
  {ok, {timeout(), KillFlag :: boolean()}} | {error, badarg}.

shutdown_options() ->
  case application:get_env(shutdown_timeout) of
    {ok, Timeout} when is_integer(Timeout), Timeout > 0; Timeout == infinity ->
      case application:get_env(shutdown_kill) of
        {ok, KillFlag} when is_boolean(KillFlag) ->
          {ok, {Timeout, KillFlag}};
        _ ->
          {error, badarg}
      end;
    _ ->
      {error, badarg}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
