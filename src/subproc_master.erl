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
  Request = {exec, self(), Command, Args, Options},
  case gen_server:call(?MODULE, Request, infinity) of
    {ok, Port} when is_port(Port) ->
      {ok, Port};
    {ok, {native, ID, {in_out, {FDR, FDW}}, PortOpts, AutoClose}} ->
      try open_port({fd, FDR, FDW}, PortOpts) of
        Port when AutoClose ->
          % register port for killing and FDs closing
          ok = gen_server:call(?MODULE, {reg, Port, native, ID, [FDR, FDW]},
                               infinity),
          {ok, Port};
        Port when not AutoClose ->
          % register port for killing
          ok = gen_server:call(?MODULE, {reg, Port, native, ID, []}, infinity),
          {ok, Port}
      catch
        error:Reason ->
          gen_server:call(?MODULE, {open_port_failed, ID}, infinity),
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
          ok = gen_server:call(?MODULE, {reg, Port, [FDR, FDW]}, infinity),
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
  case gen_server:call(?MODULE, {kill, Port, Signal}, infinity) of
    ok -> ok;
    {error, nxchild} -> {error, badarg};
    {error, Reason} -> {error, Reason}
  end.

%% @doc Reload shutdown options from application's environment.

-spec reload() ->
  ok | {error, badarg}.

reload() ->
  gen_server:call(?MODULE, reload, infinity).

%% @doc Format a reason from error tuple as a usable error message.

-spec format_error(term()) ->
  string().

format_error(Reason) ->
  subproc_master_driver:format_error(Reason).

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

terminate(_Arg, _State = #state{port = undefined, registry = Registry}) ->
  % TODO: kill the subprocesses and close all the registered ports
  ets:delete(Registry),
  ok;
terminate(_Arg, _State = #state{port = MasterPort, registry = Registry}) ->
  % TODO: kill the subprocesses and close all the registered ports
  ets:delete(Registry),
  subproc_master_driver:shutdown(MasterPort),
  % TODO: process events and wait for shutdown confirmation
  ok.

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
        {subproc, Port, ID} ->
          try subproc_worker_driver:controlling_process(Port, Owner) of
            _ ->
              % preserve (restore) link to `Port', so we can monitor its
              % shutdown
              link(Port),
              % XXX: supervisor guarantees `ID' to be unique, Erlang runtime
              % guarantees `Port' to be unique
              true = ets:insert_new(Registry, [
                {ID, Port, subproc},  % port type
                {Port, ID, []}        % FDs to close on port termination
              ]),
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

handle_call({reg, Port, CloseFDs} = _Request, _From,
            State = #state{registry = Registry}) when is_port(Port) ->
  % register a port from raw FDs
  Reply = try link(Port) of
    _ ->
      case ets:insert_new(Registry, {Port, undefined, CloseFDs}) of
        true -> ok;
        false -> {error, badarg}
      end
  catch
    _:_ -> {error, badarg}
  end,
  {reply, Reply, State};

handle_call({reg, Port, PortType, ID, CloseFDs} = _Request, _From,
            State = #state{registry = Registry})
when is_port(Port), is_list(CloseFDs) ->
  % NOTE: only native ports need registering this way
  Reply = try link(Port) of
    _ ->
      Records = [
        {ID, Port, PortType},
        {Port, ID, CloseFDs}
      ],
      case ets:insert_new(Registry, Records) of
        true -> ok;
        false -> {error, badarg}
      end
  catch
    _:_ -> {error, badarg}
  end,
  {reply, Reply, State};

handle_call({open_port_failed, ID} = _Request, _From,
            State = #state{port = MasterPort}) ->
  Reply = subproc_master_driver:kill(MasterPort, ID, default),
  {reply, Reply, State};

handle_call({kill, What, Signal} = _Request, _From,
            State = #state{port = MasterPort, registry = Registry}) ->
  Reply = case ets:lookup(Registry, What) of
    [{Port, undefined = _ID, _CloseFDs}] when is_port(Port) ->
      {error, badarg};
    [{Port, ID, _CloseFDs}] when is_port(Port) ->
      subproc_master_driver:kill(MasterPort, ID, Signal);
    [{ID, Port, _PortType}] when is_port(Port) ->
      subproc_master_driver:kill(MasterPort, ID, Signal);
    [] ->
      {error, badarg}
  end,
  {reply, Reply, State};

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

handle_info({subproc_sup, MasterPort, _EventData, _FDs} = Message,
            State = #state{port = MasterPort, registry = Registry}) ->
  % NOTE: `exec' and `exec_error' messages can only arrive on exec request,
  % and we don't have such requests running asynchronously
  case subproc_master_driver:decode_event(Message) of
    {TermType, ID, TermData} when TermType == exit; TermType == signal ->
      % subprocess terminated; `TermData' interpretation:
      %   `TermType = exit': `ExitCode'
      %   `TermType = signal': `{SigNum, SigName}'
      case ets:lookup(Registry, ID) of
        [{ID, Port, subproc = _PortType}] ->
          try
            unlink(Port),
            subproc_worker_driver:terminated(Port, {TermType, TermData})
          catch
            _:_ -> ignore
          end,
          ets:delete(Registry, ID),
          ets:delete(Registry, Port);
        [{ID, _Port, native = _PortType}] ->
          % wait for read descriptor to hit EOF and port to close
          ignore;
        [] ->
          ignore
      end,
      {noreply, State};
    {shutdown, 0 = _AliveChildren} ->
      NewState = State#state{port = undefined},
      {stop, normal, NewState};
    {shutdown, AliveChildren} when AliveChildren > 0 ->
      % TODO: log this event as operational warning
      NewState = State#state{port = undefined},
      {stop, normal, NewState};
    {error, unknown_event} ->
      % TODO: log this event as a library internal error
      {noreply, State}
  end;

handle_info({'EXIT', MasterPort, Reason} = _Message,
            State = #state{port = MasterPort}) ->
  % TODO: inform worker ports of master's death
  NewState = State#state{port = undefined},
  {stop, Reason, NewState};

handle_info({'EXIT', Port, _Reason} = _Message,
            State = #state{port = MasterPort, registry = Registry})
when is_port(Port) ->
  case ets:lookup(Registry, Port) of
    [{Port, undefined = _ID, CloseFDs}] ->
      % it was a port that was't associated with any process
      lists:foreach(fun subproc_unix:close/1, CloseFDs),
      ets:delete(Registry, Port);
    [{Port, ID, CloseFDs}] ->
      % if the subprocess already terminated, an error can be ignored
      subproc_master_driver:kill(MasterPort, ID, default),
      lists:foreach(fun subproc_unix:close/1, CloseFDs),
      ets:delete(Registry, ID),
      ets:delete(Registry, Port);
    [] ->
      ignore
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
                 close_on_exit = CloseOnExit}) ->
  case subproc_master_driver:exec(MasterPort, Command, Args, ExecOpts) of
    {ok, {ID, PID, STDIO}} when PortType == subproc ->
      OpenOptions = [
        {pid, PID},
        {close, AutoClose},
        {close_on_exit, CloseOnExit} |
        PortOpts
      ],
      case subproc_worker_driver:open(STDIO, OpenOptions) of
        {ok, Port} ->
          {subproc, Port, ID};
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
option(Option, Opts = #opts{exec_options = EOpts, port_options = POpts}) ->
  case subproc_master_driver:is_option(Option) of
    true  -> Opts#opts{exec_options = [Option | EOpts]};
    false -> Opts#opts{port_options = [Option | POpts]}
  end.

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
