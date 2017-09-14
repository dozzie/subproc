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
-export([exec/3, kill/2]).
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
  port :: subproc_master_driver:handle()
  % TODO: port => ID (port termination, kill requests)
  % TODO: ID => port (exit and signal events)
}).

-record(opts, {
  port_type = subproc :: subproc | native | raw_fd,
  native_autoclose = true :: boolean(),
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

-spec exec(file:filename(), [string()], [term()]) ->
  {ok, port() | RawInfo} | {error, bad_owner | badarg | term()}
  when RawInfo :: {ID, PID, STDIO},
       ID :: pos_integer(),
       PID :: subproc_unix:os_pid(),
       STDIO :: tuple().

exec(Command, Args, Options) ->
  Request = {exec, self(), Command, Args, Options},
  case gen_server:call(?MODULE, Request, infinity) of
    {ok, Port} when is_port(Port) ->
      {ok, Port};
    {ok, {native, _ID, {in_out, {FDR, FDW}}, PortOpts, AutoClose}} ->
      try open_port({fd, FDR, FDW}, PortOpts) of
        Port when AutoClose ->
          % TODO: register port for killing and autoclose
          {ok, Port};
        Port when not AutoClose ->
          % TODO: register port for killing
          {ok, Port}
      catch
        error:Reason ->
          % TODO: ask for killing the subprocess
          subproc_unix:close(FDR),
          subproc_unix:close(FDW),
          {error, Reason}
      end;
    {ok, {raw_fd, ID, PID, STDIO}} ->
      {ok, {ID, PID, STDIO}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Kill a child process running under unix supervisor.

-spec kill(port(), default | subproc_unix:signal()) ->
  ok | {error, nxchild | subproc_unix:posix() | badarg}.

kill(Port, Signal) ->
  gen_server:call(?MODULE, {kill, Port, Signal}, infinity).

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
  % TODO: shutdown timeout, shutdown kill option
  {ok, MasterPort} = subproc_master_driver:open([]),
  subproc_mdrv_reaper:watch(MasterPort),
  State = #state{port = MasterPort},
  {ok, State}.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State = #state{port = undefined}) ->
  ok;
terminate(_Arg, _State = #state{port = MasterPort}) ->
  subproc_master_driver:shutdown(MasterPort),
  % TODO: process events and wait for shutdown confirmation
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({exec, Owner, Command, Args, OptionList} = _Request, _From,
            State = #state{port = MasterPort}) ->
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
              % TODO: register subprocess (`ID' + `Port'), preserve (restore)
              % link to `Port'
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

handle_call({kill, _Port, _Signal} = _Request, _From,
            State = #state{port = _MasterPort}) ->
  {reply, {error, 'TODO'}, State};

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
            State = #state{port = MasterPort}) ->
  % NOTE: `exec' and `exec_error' messages can only arrive on exec request,
  % and we don't have such requests running asynchronously
  case subproc_master_driver:decode_event(Message) of
    {exit, _ID, _ExitCode} ->
      % TODO: pass this to appropriate worker port
      % TODO: unregister subprocess
      {noreply, State};
    {signal, _ID, {_SigNum, _SigName}} ->
      % TODO: pass this to appropriate worker port
      % TODO: unregister subprocess
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

handle_info({'EXIT', _Port, _Reason} = _Message,
            State = #state{port = _MasterPort}) ->
  % TODO: order master port to terminate appropriate process
  % TODO: unregister subprocess
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
    {subproc, subproc_worker_driver:handle(), subproc_master_driver:id()}
  | {native, NativePortStub :: tuple()}
  | {raw_fd, RawFDPortStub :: tuple()}
  | {error, ExecError | WorkerError}
  when ExecError :: term(),
       WorkerError :: badarg.

spawn_port(MasterPort, Command, Args,
           #opts{port_type = PortType, exec_options = ExecOpts,
                 port_options = PortOpts, native_autoclose = ACFlag}) ->
  case subproc_master_driver:exec(MasterPort, Command, Args, ExecOpts) of
    {ok, {ID, PID, STDIO}} when PortType == subproc ->
      case subproc_worker_driver:open(STDIO, [{pid, PID} | PortOpts]) of
        {ok, Port} ->
          {subproc, Port, ID};
        {error, Reason} ->
          close_stdio(STDIO),
          {error, Reason}
      end;
    {ok, {ID, _PID, STDIO}} when PortType == native ->
      PortStub = {native, ID, STDIO, PortOpts, ACFlag},
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
  case lists:foldr(fun option/2, #opts{}, Options) of
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
  end.

%% @doc Fold workhorse for {@link options/1}.

-spec option(Option :: term(), #opts{}) ->
  #opts{}.

option(subproc, Opts) -> Opts#opts{port_type = subproc};
option(native,  Opts) -> Opts#opts{port_type = native};
option(raw_fd,  Opts) -> Opts#opts{port_type = raw_fd};
option(autoclose,    Opts) -> Opts#opts{native_autoclose = true};
option(no_autoclose, Opts) -> Opts#opts{native_autoclose = false};
option(Option, Opts = #opts{exec_options = EOpts, port_options = POpts}) ->
  case subproc_master_driver:is_option(Option) of
    true  -> Opts#opts{exec_options = [Option | EOpts]};
    false -> Opts#opts{port_options = [Option | POpts]}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
