%%%---------------------------------------------------------------------------
%%% @doc
%%%   Module that exposes to Erlang selected functions from unix API and
%%%   implements translation between symbolic constants and numeric values
%%%   (signal numbers and <i>errno</i>).
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_unix).

%% unix API
-export([waitpid/1, close/1]).
%% translation functions
-export([errno_to_posix/1, signal_name/1, signal_number/1]).

-export_type([os_pid/0, os_fd/0]).
-export_type([posix/0]).
-export_type([exit_code/0, signal_name/0, signal_number/0]).

%%%---------------------------------------------------------------------------
%%% types {{{

-type os_pid() :: pos_integer().

-type os_fd() :: non_neg_integer().

-type posix() :: inet:posix().

-type exit_code() :: 0 .. 255.

-type signal_number() :: 1 .. 31.

-type signal_name() :: hup | int | quit | kill | term | usr1 | usr2
                     | abrt | alrm | stop | cont | atom().

%%% }}}
%%%---------------------------------------------------------------------------

-on_load(init/0).

init() ->
  case code:lib_dir(subproc, priv) of
    {error, Reason} ->
      error({load, Reason});
    Path ->
      erlang:load_nif(filename:join(Path, ?MODULE), 0)
  end.

%%%---------------------------------------------------------------------------
%%% unix API
%%%---------------------------------------------------------------------------

-spec waitpid(os_pid()) ->
    {ok, exit_code() | signal_name()}
  | alive
  | undefined
  | {error, badarg | posix()}.

waitpid(_Pid) ->
  "NIF library not loaded".

-spec close(os_fd()) ->
  ok | {error, badarg | posix()}.

close(_FD) ->
  "NIF library not loaded".

%%%---------------------------------------------------------------------------
%%% translation functions
%%%---------------------------------------------------------------------------

-spec errno_to_posix(integer()) ->
  posix() | unknown.

errno_to_posix(_Errno) ->
  "NIF library not loaded".

-spec signal_name(signal_number()) ->
  signal_name().

signal_name(_SigNum) ->
  "NIF library not loaded".

-spec signal_number(signal_name()) ->
  signal_number().

signal_number(_SigName) ->
  "NIF library not loaded".

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
