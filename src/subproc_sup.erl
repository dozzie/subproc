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
    {subproc_mdrv_reaper,
      {subproc_mdrv_reaper, start_link, []},
      permanent, 5000, worker, [subproc_mdrv_reaper]},
    {subproc_master,
      {subproc_master, start_link, []},
      permanent, 5000, worker, [subproc_master]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
