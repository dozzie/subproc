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
  {RsyncPath, ConfigPath, Cwd} = rsync_config(),
  case rsync_exec(RsyncPath, ConfigPath, Cwd) of
    {ok, Subproc, PID} ->
      rsyncd_log:append_context([{rsync_pid, PID}]),
      rsyncd_log:info("new connection"),
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
  subproc:close(Subproc),
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
  subproc:setopts(Subproc, [{active, once}]),
  {noreply, State};

handle_info({subproc_closed, Subproc} = _Message,
            State = #state{rsyncd = Subproc}) ->
  % this comes before exit or signal message, don't stop just yet
  {noreply, State};

handle_info({subproc_error, Subproc, Reason} = _Message,
            State = #state{rsyncd = Subproc}) ->
  rsyncd_log:warn("rsync port terminated abnormally",
                  [{error, {term, Reason}}]),
  subproc:signal(Subproc),
  {stop, normal, State};

handle_info({subproc_terminated, Subproc, exit, 0} = _Message,
            State = #state{rsyncd = Subproc}) ->
  {stop, normal, State};
handle_info({subproc_terminated, Subproc, exit, ExitCode} = _Message,
            State = #state{rsyncd = Subproc}) ->
  rsyncd_log:warn("rsync process exited with an error",
                  [{exit_code, ExitCode}]),
  {stop, normal, State};
handle_info({subproc_terminated, Subproc, signal, {_, SigName}} = _Message,
            State = #state{rsyncd = Subproc}) ->
  rsyncd_log:warn("rsync process killed", [{signal, {term, SigName}}]),
  {stop, normal, State};

handle_info({tcp, Socket, Data} = _Message,
            State = #state{socket = Socket, rsyncd = Subproc}) ->
  subproc:send(Subproc, Data),
  inet:setopts(Socket, [{active, once}]),
  {noreply, State};

handle_info({tcp_closed, Socket} = _Message,
            State = #state{socket = Socket, rsyncd = Subproc}) ->
  subproc:close(Subproc, read_write),
  {noreply, State};

handle_info({tcp_error, Socket, Reason} = _Message,
            State = #state{socket = Socket, rsyncd = Subproc}) ->
  rsyncd_log:warn("TCP socket terminated abnormally",
                  [{error, {term, Reason}}]),
  subproc:close(Subproc, read_write),
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
                 file:filename() | undefined) ->
  {ok, subproc:handle(), subproc:os_pid()} | {error, term()}.

rsync_exec(RsyncPath, ConfigPath, Cwd) ->
  RsyncArgs = ["--daemon", "--config", ConfigPath],
  BasicOptions = [
    {stdio, bidir}, {type, socket}, {termsig, hup},
    binary, {packet, raw}, {active, once}, {exit_status, true}
  ],
  Options = case Cwd of
    undefined -> BasicOptions;
    _ -> [{cd, Cwd} | BasicOptions]
  end,
  case subproc:exec(RsyncPath, RsyncArgs, Options) of
    {ok, Subproc} ->
      {ok, [{pid, PID}]} = subproc:getopts(Subproc, [pid]),
      {ok, Subproc, PID};
    {error, Reason} ->
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
