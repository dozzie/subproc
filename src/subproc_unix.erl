%%%---------------------------------------------------------------------------
%%% @doc
%%%   Module that exposes to Erlang selected functions from unix API and
%%%   implements translation between symbolic constants and numeric values
%%%   (signal numbers and <i>errno</i>).
%%% @end
%%%---------------------------------------------------------------------------

-module(subproc_unix).

%% unix API
-export([waitpid/1, close/1, getuid/0, geteuid/0, getgid/0, getegid/0]).
%% translation functions
-export([errno_to_posix/1, signal_name/1, signal_number/1]).

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

-spec waitpid(subproc:os_pid()) ->
    {ok, subproc:exit_code() | subproc:signal_name()}
  | alive
  | undefined
  | {error, badarg}.

waitpid(_Pid) ->
  erlang:nif_error(nif_not_loaded).

%% @doc `close(2)': close a file descriptor.
%%
%%   `{error,badarg}' is returned when a non-integer or a negative integer is
%%   passed as an argument.

-spec close(subproc:os_fd()) ->
  ok | {error, badarg | subproc:posix()}.

close(_FD) ->
  erlang:nif_error(nif_not_loaded).

%% @doc `getuid(2)': get UID with which BEAM VM runs.

-spec getuid() ->
  subproc:uid().

getuid() ->
  erlang:nif_error(nif_not_loaded).

%% @doc `geteuid(2)': get effective UID with which BEAM VM runs.

-spec geteuid() ->
  subproc:uid().

geteuid() ->
  erlang:nif_error(nif_not_loaded).

%% @doc `getgid(2)': get GID with which BEAM VM runs.

-spec getgid() ->
  subproc:gid().

getgid() ->
  erlang:nif_error(nif_not_loaded).

%% @doc `getegid(2)': get effective GID with which BEAM VM runs.

-spec getegid() ->
  subproc:gid().

getegid() ->
  erlang:nif_error(nif_not_loaded).

%%%---------------------------------------------------------------------------
%%% translation functions
%%%---------------------------------------------------------------------------

%% @doc Convert numeric value of `errno' to an atom.

-spec errno_to_posix(integer()) ->
  subproc:posix() | unknown.

errno_to_posix(_Errno) ->
  erlang:nif_error(nif_not_loaded).

%% @doc Convert numeric value of a signal to its name.
%%
%%   Function crashes with `error:badarg' when invalid or unknown signal
%%   number is passed.

-spec signal_name(subproc:signal_number()) ->
  subproc:signal_name().

signal_name(_SigNum) ->
  erlang:nif_error(nif_not_loaded).

%% @doc Convert signal name to its numeric value.
%%
%%   Function crashes with `error:badarg' when invalid or unknown signal
%%   name is passed.

-spec signal_number(subproc:signal_name()) ->
  subproc:signal_number().

signal_number(_SigName) ->
  erlang:nif_error(nif_not_loaded).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
