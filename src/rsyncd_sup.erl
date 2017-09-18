%%%---------------------------------------------------------------------------
%%% @doc
%%% @end
%%%---------------------------------------------------------------------------

-module(rsyncd_sup).

-behaviour(supervisor).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start the supervisor process.

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  {ok, LogHandlers} = application:get_env(log_handlers),
  Strategy = {one_for_one, 5, 10},
  Children = [
    {rsyncd_log, {rsyncd_log, start_link, [LogHandlers]},
      permanent, 1000, worker, [rsyncd_log]},
    {rsyncd_tcp_sup, {rsyncd_tcp_sup, start_link, []},
      permanent, 1000, supervisor, [rsyncd_tcp_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
