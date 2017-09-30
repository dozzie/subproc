%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Port driver loader process.
%%%
%%% @todo Reloading port drivers on code change
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_driver_loader).

-behaviour(gen_server).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-record(state, {}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start driver loader process.

start() ->
  gen_server:start(?MODULE, [], []).

%% @private
%% @doc Start driver loader process.

start_link() ->
  gen_server:start_link(?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init(_Args) ->
  case code:lib_dir(subproc, priv) of
    {error, bad_name} ->
      {stop, {missing_application, subproc}};
    PrivDir ->
      ok = erl_ddll:load(PrivDir, subproc_sup_drv),
      ok = erl_ddll:load(PrivDir, subproc_drv),
      _ = subproc_unix:getuid(), % make sure that NIF library is loaded
      process_flag(trap_exit, true),
      State = #state{},
      {ok, State}
  end.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State) ->
  erl_ddll:unload(subproc_sup_drv),
  erl_ddll:unload(subproc_drv),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

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
