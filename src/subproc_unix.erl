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
-export_type([exit_code/0, signal/0, signal_name/0, signal_number/0]).

%%%---------------------------------------------------------------------------
%%% types {{{

-type os_pid() :: pos_integer().
%% PID of an OS-level process.

-type os_fd() :: non_neg_integer().
%% File descriptor, usable for `read(2)', `write(2)', and `close(2)'.

-type posix() :: inet:posix().
%% Atom representation of an `errno' value.

-type exit_code() :: 0 .. 255.
%% Exit code of a process.

-type signal() :: signal_number() | signal_name().
%% Signal representation.

-type signal_number() :: 1 .. 31.
%% Integer value of a signal. Different OSes can assign different meaning to
%% each number; {@type signal_name()} is a more portable alternative.

-type signal_name() :: hup | int | quit | kill | term | usr1 | usr2
                     | abrt | alrm | stop | cont | atom().
%% Symbolic name of a signal. Lower case with `"SIG"' prefix stripped.

%%% }}}
%%%---------------------------------------------------------------------------

-on_load(init/0).

%% @doc Module loading hook to load NIF library.

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

%% @doc `waitpid(2)': collect status of a terminated child process.
%%
%%   This function returns immediately without waiting for child process to
%%   terminate.
%%
%%   If the process is still alive, `alive' is returned. If the process is not
%%   a child of BEAM (possibly because it was already reaped), `undefined' is
%%   returned. Invalid `Pid' results in `{error,badarg}'.
%%
%%   If a child process terminated normally, exit code (non-negative integer)
%%   is returned. If it was killed with a signal, signal's name (atom) is
%%   returned instead.

-spec waitpid(os_pid()) ->
  {ok, exit_code() | signal_name()} | alive | undefined | {error, badarg}.

waitpid(_Pid) ->
  erlang:nif_error(nif_not_loaded).

%% @doc `close(2)': close a file descriptor.
%%
%%   `{error,badarg}' is returned when a non-integer or a negative integer is
%%   passed as an argument.

-spec close(os_fd()) ->
  ok | {error, badarg | posix()}.

close(_FD) ->
  erlang:nif_error(nif_not_loaded).

%%%---------------------------------------------------------------------------
%%% translation functions
%%%---------------------------------------------------------------------------

%% @doc Convert numeric value of `errno' to an atom.

-spec errno_to_posix(integer()) ->
  posix() | unknown.

errno_to_posix(_Errno) ->
  erlang:nif_error(nif_not_loaded).

%% @doc Convert numeric value of a signal to its name.
%%
%%   Function crashes with `error:badarg' when invalid or unknown signal
%%   number is passed.

-spec signal_name(signal_number()) ->
  signal_name().

signal_name(_SigNum) ->
  erlang:nif_error(nif_not_loaded).

%% @doc Convert signal name to its numeric value.
%%
%%   Function crashes with `error:badarg' when invalid or unknown signal
%%   name is passed.

-spec signal_number(signal_name()) ->
  signal_number().

signal_number(_SigName) ->
  erlang:nif_error(nif_not_loaded).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
