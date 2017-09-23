%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Monitor for master port driver.
%%%
%%%   The process monitors `subproc''s master port, used to spawn unix
%%%   subprocesses, and on its termination reaps the remaining zombie with
%%%   {@link subproc_unix:waitpid/1}.
%%%
%%% @see subproc_master
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_mdrv_reaper).

-behaviour(gen_server).

%% public interface
-export([watch/1, unwatch/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(REAP_INTERVAL, 100).

-record(state, {
  port :: {port(), subproc:os_pid()} | undefined
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start driver monitor process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start driver monitor process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Watch a master port and reap a zombie process after its termination.

-spec watch(subproc_master_driver:handle()) ->
  ok | {error, already_watching | badarg}.

watch(Port) ->
  gen_server:call(?MODULE, {watch, Port}, infinity).

%% @doc Stop watching a master port.

-spec unwatch(subproc_master_driver:handle()) ->
  ok | {error, port_not_watched}.

unwatch(Port) ->
  gen_server:call(?MODULE, {unwatch, Port}, infinity).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init(_Args) ->
  process_flag(trap_exit, true),
  State = #state{},
  {ok, State}.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State = #state{port = undefined}) ->
  ok;
terminate(Arg, _State = #state{port = {Port, PID}}) ->
  try
    % NOTE: exit should not propagate because of `trap_exit' flag
    exit(Port, Arg)
  catch
    _:_ -> ignore
  end,
  waitpid(PID, ?REAP_INTERVAL),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({watch, Port} = _Request, _From,
            State = #state{port = undefined}) ->
  try
    PID = subproc_master_driver:pidof(Port),
    link(Port),
    NewState = State#state{port = {Port, PID}},
    {reply, ok, NewState}
  catch
    _:_ ->
      {reply, {error, badarg}, State}
  end;

handle_call({watch, _NewPort} = _Request, _From,
            State = #state{port = {_Port, _PID}}) ->
  {reply, {error, already_watching}, State};

handle_call({unwatch, Port} = _Request, _From,
            State = #state{port = {Port, _PID}}) ->
  NewState = State#state{port = undefined},
  try
    unlink(Port)
  catch
    _:_ -> ignore
  end,
  {reply, ok, NewState};
handle_call({unwatch, _Port} = _Request, _From,
            State = #state{port = undefined}) ->
  {reply, ok, State};
handle_call({unwatch, _NewPort} = _Request, _From,
            State = #state{port = {_Port, _PID}}) ->
  {reply, {error, port_not_watched}, State};

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

handle_info({'EXIT', Port, _Reason} = _Message,
            State = #state{port = {Port, PID}}) ->
  ok = waitpid(PID, ?REAP_INTERVAL),
  NewState = State#state{port = undefined},
  {noreply, NewState};

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

%% @doc Reap a zombie process after master port's termination.

-spec waitpid(subproc:os_pid(), pos_integer()) ->
  ok.

waitpid(PID, WaitPidInterval) ->
  case subproc_unix:waitpid(PID) of
    alive ->
      timer:sleep(WaitPidInterval),
      waitpid(PID, WaitPidInterval);
    {ok, _CodeOrSignal} ->
      ok;
    undefined ->
      ok
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
