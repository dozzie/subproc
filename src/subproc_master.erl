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
  {ok, port()} | {error, term()}.

exec(Command, Args, Options) ->
  gen_server:call(?MODULE, {exec, self(), Command, Args, Options}, infinity).

%% @doc Kill a child process running under unix supervisor.

-spec kill(port(), default | subproc_unix:signal_name() |
                   subproc_unix:signal_number()) ->
  ok | {error, nxchild | subproc_unix:posix() | badarg}.

kill(Port, Signal) ->
  gen_server:call(?MODULE, {kill, Port, Signal}, infinity).

%% @doc Format an error reported by this module.

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

handle_call({exec, _Owner, Command, Args, Options} = _Request, _From,
            State = #state{port = MasterPort}) ->
  case subproc_master_driver:exec(MasterPort, Command, Args, Options) of
    {ok, {ID, PID, STDIO}} ->
      % TODO: spawn a worker port, register subprocess, make `Owner' the owner
      % of the worker port, preserve link to the worker port
      Result = {ID, PID, STDIO},
      {reply, {ok, Result}, State};
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
%%% vim:ft=erlang:foldmethod=marker
