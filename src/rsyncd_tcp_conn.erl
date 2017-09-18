%%%---------------------------------------------------------------------------
%%% @doc
%%%   Client connection worker.
%%% @end
%%%---------------------------------------------------------------------------

-module(rsyncd_tcp_conn).

-behaviour(gen_server).

%% public interface
-export([take_over/1]).

%% supervision tree API
-export([start/1, start_link/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-record(state, {
  socket :: gen_tcp:socket(),
  rsyncd :: subproc:handle()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a worker process, taking over a client socket.
%%
%%   The caller must be the controlling process of the `Socket'.
%%
%%   In case of spawning error, the socket is closed. In any case, caller
%%   shouldn't bother with the socket anymore.

-spec take_over(gen_tcp:socket()) ->
  {ok, pid()} | {error, term()}.

take_over(Socket) ->
  case rsyncd_tcp_conn_sup:spawn_worker(Socket) of
    {ok, Pid} ->
      ok = gen_tcp:controlling_process(Socket, Pid),
      inet:setopts(Socket, [binary, {packet, raw}, {active, once}]),
      {ok, Pid};
    {error, Reason} ->
      gen_tcp:close(Socket),
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start worker process.

start(Socket) ->
  gen_server:start(?MODULE, [Socket], []).

%% @private
%% @doc Start worker process.

start_link(Socket) ->
  gen_server:start_link(?MODULE, [Socket], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([Socket] = _Args) ->
  % XXX: we can't read the request here, as parent supervisor waits init() to
  % return
  {ok, {PeerAddr, PeerPort}} = inet:peername(Socket),
  {ok, {LocalAddr, LocalPort}} = inet:sockname(Socket),
  rsyncd_log:set_context(connection, [
    {client, {str, format_address(PeerAddr, PeerPort)}},
    {local_address, {str, format_address(LocalAddr, LocalPort)}}
  ]),
  rsyncd_log:info("new connection"),
  {RsyncPath, ConfigPath, Cwd} = rsync_config(),
  case rsync_exec(RsyncPath, ConfigPath, Cwd) of
    {ok, Subproc} ->
      State = #state{
        socket = Socket,
        rsyncd = Subproc
      },
      {ok, State};
    {error, Reason} ->
      CwdLog = case Cwd of
        undefined -> [];
        _ -> [{cwd, {str, Cwd}}]
      end,
      rsyncd_log:warn("rsync spawn error", [
        {error, {term, Reason}},
        {rsync, {str, RsyncPath}},
        {config, {str, ConfigPath}} |
        CwdLog
      ]),
      {stop, Reason}
  end.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{socket = Socket, rsyncd = Subproc}) ->
  gen_tcp:close(Socket),
  subproc_worker_driver:close(Subproc, read_write),
  % TODO: wait for the process to terminate
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

handle_info({subproc, Subproc, Data} = _Message,
            State = #state{socket = Socket, rsyncd = Subproc}) ->
  gen_tcp:send(Socket, Data),
  subproc_worker_driver:setopts(Subproc, [{active, once}]),
  {noreply, State};

handle_info({subproc_closed, Subproc} = _Message,
            State = #state{rsyncd = Subproc}) ->
  % TODO: this comes before exit or signal message, don't stop just yet
  {stop, normal, State};

handle_info({subproc_error, Subproc, _Reason} = _Message,
            State = #state{rsyncd = Subproc}) ->
  % TODO: log this
  {stop, normal, State};

handle_info({subproc_exit, Subproc, _ExitCode} = _Message,
            State = #state{rsyncd = Subproc}) ->
  % TODO: log this if `ExitCode' is non-zero
  {stop, normal, State};

handle_info({subproc_signal, Subproc, {_SigNum, _SigName}} = _Message,
            State = #state{rsyncd = Subproc}) ->
  % TODO: log this
  {stop, normal, State};

handle_info({tcp, Socket, Data} = _Message,
            State = #state{socket = Socket, rsyncd = Subproc}) ->
  subproc_worker_driver:send(Subproc, Data),
  inet:setopts(Socket, [{active, once}]),
  {noreply, State};

handle_info({tcp_closed, Socket} = _Message,
            State = #state{socket = Socket}) ->
  {stop, normal, State};

handle_info({tcp_error, Socket, _Reason} = _Message,
            State = #state{socket = Socket}) ->
  % TODO: log this
  {stop, normal, State};

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
%%% helper functions
%%%---------------------------------------------------------------------------

%% @doc Format IP address and port number for logging.

-spec format_address(inet:ip_address(), inet:port_number()) ->
  string().

format_address({A,B,C,D} = _Address, Port) ->
  % TODO: IPv6
  OctetList = [
    integer_to_list(A),
    integer_to_list(B),
    integer_to_list(C),
    integer_to_list(D)
  ],
  string:join(OctetList, ".") ++ ":" ++ integer_to_list(Port).

rsync_config() ->
  {ok, ConfigPath} = application:get_env(rsyncd_conf),
  {ok, RsyncPath} = application:get_env(rsync_path),
  case application:get_env(cwd) of
    {ok, Cwd} -> {RsyncPath, ConfigPath, Cwd};
    undefined -> {RsyncPath, ConfigPath, undefined}
  end.

-spec rsync_exec(file:filename(), file:filename(),
                 filename:filename() | undefined) ->
  {ok, subproc:handle()} | {error, term()}.

rsync_exec(RsyncPath, ConfigPath, Cwd) ->
  RsyncArgs = ["--daemon", "--config", ConfigPath],
  Options = [
    {stdio, bidir}, {type, socket}, {termsig, hup},
    binary, {packet, raw}, {active, once}
  ],
  case Cwd of
    undefined -> subproc_master:exec(RsyncPath, RsyncArgs, Options);
    _ -> subproc_master:exec(RsyncPath, RsyncArgs, [{cd, Cwd} | Options])
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
