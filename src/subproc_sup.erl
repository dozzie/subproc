%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Top-level supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_sup).

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
  Strategy = {one_for_one, 5, 10},
  Children = [
    {subproc_driver_loader,
      {subproc_driver_loader, start_link, []},
      permanent, 5000, worker, [subproc_driver_loader]},
    {subproc_mdrv_reaper,
      {subproc_mdrv_reaper, start_link, []},
      permanent, 5000, worker, [subproc_mdrv_reaper]},
    {subproc_master,
      {subproc_master, start_link, []},
      permanent, subproc_master_timeout(), worker, [subproc_master]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------

%% @doc Get shutdown timeout for `subproc_master' process.
%%   The function accounts for shutdown timeout for subprocesses and for kill
%%   flag.

-spec subproc_master_timeout() ->
  timeout().

subproc_master_timeout() ->
  {ok, KillFlag} = application:get_env(shutdown_kill),
  case application:get_env(shutdown_timeout) of
    {ok, infinity} -> infinity;
    {ok, T} when is_integer(T), T > 0, KillFlag -> 2 * T + 500;
    {ok, T} when is_integer(T), T > 0, not KillFlag -> T + 500
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
