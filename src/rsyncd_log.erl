%%%---------------------------------------------------------------------------
%%% @doc
%%%   Event log collector process and logging functions.
%%%
%%%   Process conforms to {@link gen_event} interface and loads all the event
%%%   handlers (a list of tuples {@type @{atom(), term()@}}).
%%%
%%%   The events send with these functions have following structure:
%%%   {@type @{log, pid(), info | warning | error, event_type(),
%%%     event_info()@}}.
%%% @end
%%%---------------------------------------------------------------------------

-module(rsyncd_log).

%% logging interface
-export([set_context/2, append_context/1, get_context/0]).
-export([info/1, warn/1, err/1]).
-export([info/2, warn/2, err/2]).
-export([info/3, warn/3, err/3]).
%% event serialization
-export([to_string/1]).

%% supervision tree API
-export([start/1, start_link/1]).

%% public interface
-export([reload/1]).

-export_type([event_type/0, event_info/0, event_message/0]).

%%%---------------------------------------------------------------------------

-type event_info() ::
  [{atom(), indira_json:struct() | {term, term()} | {str, string()}}].

-type event_type() :: atom().

-type event_message() :: string() | binary().

%%%---------------------------------------------------------------------------
%%% logging interface
%%%---------------------------------------------------------------------------

%% @doc Set logging context.

-spec set_context(event_type(), event_info()) ->
  ok.

set_context(EventType, EventInfo) ->
  put('$rsyncd_log', {EventType, EventInfo}),
  ok.

%% @doc Append information to logging context.

-spec append_context(event_info()) ->
  ok.

append_context(EventInfo) ->
  {EventType, EventContext} = get('$rsyncd_log'),
  put('$rsyncd_log', {EventType, EventContext ++ EventInfo}),
  ok.

%% @doc Get logging context.

-spec get_context() ->
  {event_type(), event_info()} | undefined.

get_context() ->
  get('$rsyncd_log').

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec info(event_message()) ->
  ok.

info(Message) ->
  {EventType, EventContext} = get_context(),
  event(info, EventType, [{message, message(Message)} | EventContext]).

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec info(event_message(), event_info()) ->
  ok.

info(Message, EventInfo) ->
  {EventType, EventContext} = get_context(),
  event(info, EventType,
        [{message, message(Message)} | EventInfo] ++ EventContext).

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.

-spec info(event_type(), event_message(), event_info()) ->
  ok.

info(EventType, Message, EventInfo) ->
  event(info, EventType, [{message, message(Message)} | EventInfo]).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of rsyncd application.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec warn(event_message()) ->
  ok.

warn(Message) ->
  {EventType, EventContext} = get_context(),
  event(warning, EventType, [{message, message(Message)} | EventContext]).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of rsyncd application.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec warn(event_message(), event_info()) ->
  ok.

warn(Message, EventInfo) ->
  {EventType, EventContext} = get_context(),
  event(warning, EventType,
        [{message, message(Message)} | EventInfo] ++ EventContext).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of rsyncd application.

-spec warn(event_type(), event_message(), event_info()) ->
  ok.

warn(EventType, Message, EventInfo) ->
  event(warning, EventType, [{message, message(Message)} | EventInfo]).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).
%%
%%   Function expects {@link set_context/2} to be called first.

-spec err(event_message()) ->
  ok.

err(Message) ->
  {EventType, EventContext} = get_context(),
  event(error, EventType, [{message, message(Message)} | EventContext]).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).
%%
%%   Function expects {@link set_context/2} to be called first.

-spec err(event_message(), event_info()) ->
  ok.

err(Message, EventInfo) ->
  {EventType, EventContext} = get_context(),
  event(error, EventType,
        [{message, message(Message)} | EventInfo] ++ EventContext).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).

-spec err(event_type(), event_message(), event_info()) ->
  ok.

err(EventType, Message, EventInfo) ->
  event(error, EventType, [{message, message(Message)} | EventInfo]).

%%----------------------------------------------------------
%% logging interface helpers
%%----------------------------------------------------------

%% @doc Send an event to the logger.

-spec event(info | warning | error, event_type(), event_info()) ->
  ok.

event(Level, Type, Info) ->
  gen_event:notify(?MODULE, {log, self(), Level, Type, Info}).

%% @doc Ensure that event message is a binary.

-spec message(event_message()) ->
  binary().

message(Message) when is_list(Message) ->
  list_to_binary(Message);
message(Message) when is_binary(Message) ->
  Message.

%%%---------------------------------------------------------------------------
%%% event serialization
%%%---------------------------------------------------------------------------

%% @doc Convert {@type event_info()} to JSON string.
%%
%% @see indira_json:encode/1

-spec to_string(event_info()) ->
  iolist().

to_string(Data) ->
  {ok, JSON} = indira_json:encode([{K, struct_or_string(V)} || {K,V} <- Data]),
  JSON.

%% @doc Convert single value from {@type event_info()} to something
%%   JSON-serializable.

-spec struct_or_string(Entry) ->
  indira_json:struct()
  when Entry :: indira_json:struct() | {term, term()} | {str, string()}.

struct_or_string({term, Term} = _Entry) ->
  % 4GB line limit should be more than enough to have it in a single line
  iolist_to_binary(io_lib:print(Term, 1, 16#FFFFFFFF, -1));
struct_or_string({str, String} = _Entry) ->
  % even if the string is a binary, this will convert it all to a binary
  iolist_to_binary(String);
struct_or_string(Entry) ->
  Entry.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start log collector process.

-spec start([{gen_event:handler(), gen_event:handler_args()}]) ->
  {ok, pid()} | {error, Reason}
  when Reason :: {gen_event:handler(), term()}
               | {exit, gen_event:handler(), term()}
               | {already_started, pid()}.

start(Handlers) ->
  case gen_event:start({local, ?MODULE}) of
    {ok, Pid} ->
      case sync_handlers(Pid, Handlers) of
        {ok, _ReloadCandidates} ->
          {ok, Pid};
        {error, Reason} ->
          gen_event:stop(Pid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @private
%% @doc Start log collector process.

-spec start_link([{gen_event:handler(), gen_event:handler_args()}]) ->
  {ok, pid()} | {error, Reason}
  when Reason :: {gen_event:handler(), term()}
               | {exit, gen_event:handler(), term()}
               | {already_started, pid()}.

start_link(Handlers) ->
  case gen_event:start_link({local, ?MODULE}) of
    {ok, Pid} ->
      case sync_handlers(Pid, Handlers) of
        {ok, _ReloadCandidates} ->
          {ok, Pid};
        {error, Reason} ->
          gen_event:stop(Pid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Reload list of event handlers, adding missing and removing excessive
%%   ones.
%%
%%   Function returns a list of handlers from `ExpectedHandlers' that already
%%   were present in event manager. These are the candidates for being
%%   reloaded.

-spec reload([{gen_event:handler(),gen_event:handler_args()}]) ->
  {ok, ReloadCandidates} | {error, Reason}
  when ReloadCandidates :: [gen_event:handler()],
       Reason :: {gen_event:handler(), term()}
               | {exit, gen_event:handler(), term()}.

reload(ExpectedHandlers) ->
  case sync_handlers(whereis(?MODULE), ExpectedHandlers) of
    {ok, {ExistingSet, ExpectedSet}} ->
      ReloadCandidates = sets:intersection(ExistingSet, ExpectedSet),
      {ok, sets:to_list(ReloadCandidates)};
    {error, Reason} ->
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------

-spec sync_handlers(pid(), [{gen_event:handler(),gen_event:handler_args()}]) ->
  {ok, {ExistingSet :: set(), ExpectedSet :: set()}} | {error, Reason}
  when Reason :: {gen_event:handler(), term()}
               | {exit, gen_event:handler(), term()}.

sync_handlers(Pid, ExpectedHandlers) ->
  ExpectedSet = sets:from_list([H || {H, _Args} <- ExpectedHandlers]),
  ExistingSet = sets:from_list(gen_event:which_handlers(Pid)),
  case add_missing(ExpectedHandlers, Pid, ExistingSet) of
    ok ->
      % XXX: remove_excessive() always succeeds
      ok = remove_excessive(Pid, sets:subtract(ExistingSet, ExpectedSet)),
      {ok, {ExistingSet, ExpectedSet}};
    {error, Reason} ->
      {error, Reason}
  end.

add_missing([] = _ExpectedHandlers, _Pid, _ExistingSet) ->
  ok;
add_missing([{H, Args} | Rest] = _ExpectedHandlers, Pid, ExistingSet) ->
  case sets:is_element(H, ExistingSet) of
    true ->
      add_missing(Rest, Pid, ExistingSet);
    false ->
      case gen_event:add_handler(Pid, H, Args) of
        ok -> add_missing(Rest, Pid, ExistingSet);
        {error, Reason} -> {error, {H, Reason}};
        {'EXIT', Reason} -> {error, {exit, H, Reason}}
      end
  end.

remove_excessive(Pid, ToRemoveSet) ->
  % XXX: assume that all handlers are removed successfully
  sets:fold(fun remove/2, Pid, ToRemoveSet),
  ok.

remove(Handler, Pid) ->
  gen_event:delete_handler(Pid, Handler, []),
  Pid.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
