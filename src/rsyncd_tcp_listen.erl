%%%---------------------------------------------------------------------------
%%% @doc
%%%   Connection acceptor process.
%%% @end
%%%---------------------------------------------------------------------------

-module(rsyncd_tcp_listen).

-behaviour(gen_server).

%% supervision tree API
-export([start/2, start_link/2]).

%% config reloading
-export([rebind/1, shutdown/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(ACCEPT_LOOP_INTERVAL, 100).
-define(REBIND_LOOP_INTERVAL, 5000).

-record(state, {
  socket :: gen_tcp:socket() | undefined,
  address :: rsyncd:address(),
  bind_address :: any | inet:ip_address(),
  port :: inet:port_number()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start acceptor process.

start(Addr, Port) ->
  gen_server:start(?MODULE, [Addr, Port], []).

%% @private
%% @doc Start acceptor process.

start_link(Addr, Port) ->
  gen_server:start_link(?MODULE, [Addr, Port], []).

%%%---------------------------------------------------------------------------
%%% config reloading
%%%---------------------------------------------------------------------------

%% @doc Re-bind socket to the listen address.
%%
%%   It's mainly useful when DNS entry for the address has changed.

-spec rebind(pid()) ->
  ok | {error, term()}.

rebind(Pid) ->
  gen_server:call(Pid, rebind, infinity).

%% @doc Shutdown the listener.

-spec shutdown(pid()) ->
  ok.

shutdown(Pid) ->
  gen_server:call(Pid, shutdown).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init([Addr, Port] = _Args) ->
  rsyncd_log:set_context(connection, [
    {address, format_address(Addr, Port)}
  ]),
  case resolve(Addr) of
    {ok, BindAddr} ->
      case listen(BindAddr, Port) of
        {ok, Socket} ->
          rsyncd_log:info("listening on socket",
                          [{bind_address, format_address(BindAddr)}]),
          State = #state{
            socket = Socket,
            address = Addr,
            bind_address = BindAddr,
            port = Port
          },
          {ok, State, 0};
        {error, Reason} ->
          rsyncd_log:err("can't setup listening socket", [
            {action, setup},
            {error, {term, Reason}},
            {bind_address, format_address(BindAddr)}
          ]),
          {stop, {listen, Reason}}
      end;
    {error, Reason} ->
      rsyncd_log:err("can't resolve bind address",
                     [{action, setup}, {error, {term, Reason}}]),
      {stop, {resolve, Reason}}
  end.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State = #state{socket = Socket}) ->
  close(Socket),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call(rebind = _Request, _From, State) ->
  case rebind_state(State) of
    {ok, State} ->
      % stay silent
      {reply, ok, State, 0};
    {ok, NewState = #state{bind_address = NewBindAddr}} ->
      rsyncd_log:info("rebound to a new address",
                      [{bind_address, format_address(NewBindAddr)}]),
      {reply, ok, NewState, 0};
    {error, Reason, NewState} ->
      case Reason of
        {resolve, E} ->
          rsyncd_log:err("can't resolve bind address",
                         [{action, rebind}, {error, {term, E}}]);
        {listen, E} ->
          rsyncd_log:err("can't setup listening socket", [
            {action, rebind},
            {error, {term, E}},
            {bind_address, format_address(NewState#state.bind_address)}
          ])
      end,
      {reply, {error, Reason}, NewState, ?REBIND_LOOP_INTERVAL}
  end;

handle_call(shutdown = _Request, _From, State) ->
  rsyncd_log:info("shutting down listening socket"),
  {stop, normal, ok, State};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State, 0}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State, 0}.

%% @private
%% @doc Handle incoming messages.

handle_info(timeout = _Message, State = #state{socket = undefined}) ->
  case rebind_state(State) of
    {ok, NewState = #state{bind_address = NewBindAddr}} ->
      rsyncd_log:info("rebound to a new address",
                      [{bind_address, format_address(NewBindAddr)}]),
      {noreply, NewState, 0};
    {error, _Reason, NewState} ->
      % stay silent
      {noreply, NewState, ?REBIND_LOOP_INTERVAL}
  end;

handle_info(timeout = _Message, State = #state{socket = Socket}) ->
  case gen_tcp:accept(Socket, ?ACCEPT_LOOP_INTERVAL) of
    {ok, Client} ->
      rsyncd_tcp_conn:take_over(Client),
      {noreply, State, 0};
    {error, timeout} ->
      % OK, no incoming connection
      {noreply, State, 0};
    {error, Reason} ->
      rsyncd_log:err("accept error", [{error, {term, Reason}}]),
      {stop, {accept, Reason}, State}
  end;

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State, 0}.

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

%% @doc Re-bind a listening socket if bind address changed.

-spec rebind_state(#state{}) ->
  {ok, #state{}} | {error, Reason, #state{}}
  when Reason :: {resolve | listen, inet:posix()}.

rebind_state(State = #state{socket = Socket, address = Addr, port = Port,
                            bind_address = BindAddr}) ->
  case resolve(Addr) of
    {ok, BindAddr} when Socket /= undefined ->
      % socket present and the same as old bind address; do nothing
      {ok, State};
    {ok, NewBindAddr} ->
      % either a new bind address or the socket is closed
      close(Socket),
      case listen(NewBindAddr, Port) of
        {ok, NewSocket} ->
          NewState = State#state{
            socket = NewSocket,
            bind_address = NewBindAddr
          },
          {ok, NewState};
        {error, Reason} ->
          NewState = State#state{
            socket = undefined,
            bind_address = NewBindAddr
          },
          {error, {listen, Reason}, NewState}
      end;
    {error, Reason} ->
      close(Socket),
      NewState = State#state{socket = undefined},
      {error, {resolve, Reason}, NewState}
  end.

%%%---------------------------------------------------------------------------

%% @doc Bind to a port and (possibly) IP address.

-spec listen(any | inet:ip_address(), inet:port_number()) ->
  {ok, gen_tcp:socket()} | {error, system_limit | inet:posix()}.

listen(BindAddr, Port) ->
  Options = [
    binary, {packet, raw}, {active, false},
    {reuseaddr, true}, {keepalive, true}
  ],
  case BindAddr of
    any -> gen_tcp:listen(Port, Options);
    _   -> gen_tcp:listen(Port, [{ip, BindAddr} | Options])
  end.

%% @doc Close a TCP listening socket.

-spec close(gen_tcp:socket() | undefined) ->
  ok.

close(undefined = _Socket) ->
  ok;
close(Socket) ->
  gen_tcp:close(Socket).

%% @doc Resolve hostname to an IP address.
%%
%% @todo IPv6 support

-spec resolve(rsyncd:address()) ->
  {ok, any | inet:ip_address()} | {error, inet:posix()}.

resolve(any = _Address) ->
  {ok, any};
resolve({_,_,_,_} = Address) ->
  {ok, Address};
resolve(Address) when is_list(Address); is_atom(Address) ->
  inet:getaddr(Address, inet).

%%%---------------------------------------------------------------------------

%% @doc Make a printable string from an address/port pair.

-spec format_address(rsyncd:address(), inet:port_number()) ->
  binary().

format_address(Addr, Port) ->
  iolist_to_binary([format_address(Addr), $:, integer_to_list(Port)]).

%% @doc Make a printable string from an address.
%%
%% @todo IPv6 support

-spec format_address(rsyncd:address()) ->
  binary().

format_address(any = _Addr) ->
  <<"*">>;
format_address(Addr) when is_atom(Addr) ->
  atom_to_binary(Addr, utf8);
format_address(Addr) when is_list(Addr) ->
  list_to_binary(Addr);
format_address({A,B,C,D} = _Addr) ->
  iolist_to_binary([
    integer_to_list(A), $., integer_to_list(B), $.,
    integer_to_list(C), $., integer_to_list(D)
  ]).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
