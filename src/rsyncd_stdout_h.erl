%%%---------------------------------------------------------------------------
%%% @doc
%%%   Handler for {@link rsyncd_log} to print logs to screen.
%%% @end
%%%---------------------------------------------------------------------------

-module(rsyncd_stdout_h).

-behaviour(gen_event).

%% gen_event callbacks
-export([init/1, terminate/2]).
-export([handle_event/2, handle_call/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------

-record(state, {}).

%%%---------------------------------------------------------------------------
%%% gen_event callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init(_Args) ->
  State = #state{},
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State) ->
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_event:notify/2}.

handle_event({log, Pid, Level, Type, Info} = _Event, State) ->
  try
    Msg = rsyncd_log:to_string(Info),
    io:fwrite(user, "[rsyncd] ~p ~s ~s ~s~n", [Pid, Level, Type, Msg])
  catch
    % serialization errors
    error:_ -> ignore
  end,
  {ok, State};

%% unknown events
handle_event(_Event, State) ->
  {ok, State}.

%% @private
%% @doc Handle {@link gen_event:call/2}.

%% unknown calls
handle_call(_Request, State) ->
  {ok, {error, unknown_call}, State}.

%% @private
%% @doc Handle incoming messages.

%% unknown messages
handle_info(_Message, State) ->
  {ok, State}.

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
