#!/usr/bin/estap
%%
%% Subprocess works in a simple manner, just writes to STDOUT and exits.
%%
%%----------------------------------------------------------------------------
%% fundamental test if Perl can be executed with subproc {{{

-test("check and prepare environment").
start_subproc_app() ->
  case perl_path() of
    false ->
      estap:bail_out("can't find Perl executable");
    PerlPath ->
      estap:info(["Perl executable: ", PerlPath]),
      estap:pass("finding Perl executable")
  end,
  % XXX: adding path manually is because estap is underdeveloped and with path
  % added by it the code fails at `code:lib_dir(subproc,priv)'
  {ok, CWD} = file:get_cwd(),
  code:add_patha(filename:join(CWD, "ebin")),
  case estap:ok(application:start(subproc), "start `subproc' application") of
    ok ->
      ok;
    {error, StartError} ->
      estap:bail_out(["can't start `subproc' application: ",
                      estap:explain(StartError)])
  end,
  case subproc:exec(perl_path(), ["-le", "print 'success'; exit 8"], []) of
    {ok, Perl} ->
      estap:ok(expected(Perl, ["success\n", eof]), "Perl output"),
      estap:is(wait_exit(Perl, 1000), {exit, 8}, "Perl exit status"),
      subproc:close(Perl);
    {error, ExecError} ->
      estap:bail_out(["can't execute Perl: ", estap:explain(ExecError)])
  end,
  estap:all_ok().

%% }}}
%%----------------------------------------------------------------------------
%% packet parsing tests {{{

-test("{packet,line}").
test_recv_line() ->
  {ok, Port} = perl("scripts/packet", ["line"], [{packet, line}]),
  expected(Port, ["one\n", "two\n", "three\n", "four\n", eof, {error, closed}]).

-test("{packet,line}, binary").
test_recv_line_binary() ->
  {ok, Port} = perl("scripts/packet", ["line"], [{packet, line}, binary]),
  expected(Port, [
    <<"one\n">>, <<"two\n">>, <<"three\n">>, <<"four\n">>,
    eof, {error, closed}
  ]).

-test("{packet,line}, incomplete last line").
test_recv_line_incomplete() ->
  {ok, Port} = perl("scripts/packet", ["line-incomplete"], [{packet, line}]),
  expected(Port, ["one\n", "two\n", "three\n", "four\n", {error, closed}]).

-test("{packet,line}, packet too big").
test_recv_line_too_big() ->
  {ok, Port} = perl("scripts/packet", ["line-too-big"],
                    [{packet, line}, {packet_size, 40}]),
  expected(Port, [
    "one\n", "two\n", "three\n", "four\n",
    {error, emsgsize}, {error, closed}
  ]).

-test("{packet,1}").
test_recv_1() ->
  {ok, Port} = perl("scripts/packet", ["1"], [{packet, 1}]),
  expected(Port, ["one", "two", "three", "four", eof]).

-test("{packet,2}").
test_recv_2() ->
  {ok, Port} = perl("scripts/packet", ["2"], [{packet, 2}]),
  expected(Port, ["one", "two", "three", "four", eof]).

-test("{packet,4}").
test_recv_4() ->
  {ok, Port} = perl("scripts/packet", ["4"], [{packet, 4}]),
  expected(Port, ["one", "two", "three", "four", eof]).

-test("{packet,4}, binary").
test_recv_4_binary() ->
  {ok, Port} = perl("scripts/packet", ["4"], [{packet, 4}, binary]),
  expected(Port, [<<"one">>, <<"two">>, <<"three">>, <<"four">>, eof]).

-test("{packet,4}, incomplete last one").
test_recv_4_incomplete() ->
  {ok, Port} = perl("scripts/packet", ["4-incomplete"], [{packet, 4}]),
  expected(Port, ["one", "two", "three", "four", {error, closed}]).

-test("{packet,4}, incomplete header").
test_recv_4_incomplete_header() ->
  {ok, Port} = perl("scripts/packet", ["4-incomplete-header"], [{packet, 4}]),
  expected(Port, ["one", "two", "three", "four", {error, closed}]).

-test("{packet,4}, packet too big").
test_recv_4_too_big() ->
  {ok, Port} = perl("scripts/packet", ["4-too-big"],
                    [{packet, 4}, {packet_size, 40}]),
  expected(Port, [
    "one", "two", "three", "four",
    {error, emsgsize}, {error, closed}
  ]).

-test("{packet,raw} after subprocess exited").
test_recv_raw_after_exit() ->
  {ok, Port} = perl("scripts/packet", ["line"], [{packet, raw}]),
  estap:is(wait_exit(Port, 1000), {exit, 0}, "exit"),
  estap:ok(expected(Port, ["one\ntwo\nthree\nfour\n", eof]), "output"),
  estap:all_ok().

-test("{packet,line} -> {packet,4}").
test_recv_line_4() ->
  {ok, Port} = perl("scripts/packet", ["line-4"], []),
  ok = subproc:setopts(Port, [{packet, line}]),
  estap:ok(expected(Port, ["l-one\n", "l-two\n", "l-three\n", "l-four\n"]),
           "{packet,line}"),
  ok = subproc:setopts(Port, [{packet, 4}]),
  estap:ok(expected(Port, ["4-one", "4-two", "4-three", "4-four", eof]),
           "{packet,4}"),
  estap:all_ok().

-test("{packet,4} -> {packet,line}").
test_recv_4_line() ->
  {ok, Port} = perl("scripts/packet", ["4-line"], []),
  ok = subproc:setopts(Port, [{packet, 4}]),
  estap:ok(expected(Port, ["4-one", "4-two", "4-three", "4-four"]),
           "{packet,4}"),
  ok = subproc:setopts(Port, [{packet, line}]),
  estap:ok(expected(Port, ["l-one\n", "l-two\n", "l-three\n", "l-four\n", eof]),
           "{packet,line}"),
  estap:all_ok().

%% }}}
%%----------------------------------------------------------------------------
%% active tests {{{

-test("{active,true} {packet,line}").
test_active_line() ->
  {ok, Port} = perl("scripts/packet", ["line"], [{packet, line}]),
  expected(Port, {active, 100}, [
    "one\n", "two\n", "three\n", "four\n",
    eof, timeout
  ]).

-test("{active,true} {packet,line}, binary").
test_active_line_binary() ->
  {ok, Port} = perl("scripts/packet", ["line"], [{packet, line}, binary]),
  expected(Port, {active, 100}, [
    <<"one\n">>, <<"two\n">>, <<"three\n">>, <<"four\n">>,
    eof, timeout
  ]).

-test("{active,true} {packet,line}, incomplete last line").
test_active_line_incomplete() ->
  {ok, Port} = perl("scripts/packet", ["line-incomplete"], [{packet, line}]),
  expected(Port, {active, 100}, [
    "one\n", "two\n", "three\n", "four\n",
    {error, closed}, timeout
  ]).

-test("{active,true} {packet,line}, packet too big").
test_active_line_too_big() ->
  {ok, Port} = perl("scripts/packet", ["line-too-big"],
                    [{packet, line}, {packet_size, 40}]),
  expected(Port, {active, 100}, [
    "one\n", "two\n", "three\n", "four\n",
    {error, emsgsize}, timeout
  ]).

-test("{active,true} {packet,1}").
test_active_1() ->
  {ok, Port} = perl("scripts/packet", ["1"], [{packet, 1}]),
  expected(Port, {active, 100}, ["one", "two", "three", "four", eof]).

-test("{active,true} {packet,2}").
test_active_2() ->
  {ok, Port} = perl("scripts/packet", ["2"], [{packet, 2}]),
  expected(Port, {active, 100}, ["one", "two", "three", "four", eof]).

-test("{active,true} {packet,4}").
test_active_4() ->
  {ok, Port} = perl("scripts/packet", ["4"], [{packet, 4}]),
  expected(Port, {active, 100}, ["one", "two", "three", "four", eof]).

-test("{active,true} {packet,4}, binary").
test_active_4_binary() ->
  {ok, Port} = perl("scripts/packet", ["4"], [{packet, 4}, binary]),
  expected(Port, {active, 100}, [
    <<"one">>, <<"two">>, <<"three">>, <<"four">>,
    eof
  ]).

-test("{active,true} {packet,4}, incomplete last one").
test_active_4_incomplete() ->
  {ok, Port} = perl("scripts/packet", ["4-incomplete"], [{packet, 4}]),
  expected(Port, {active, 100}, [
    "one", "two", "three", "four",
    {error, closed}
  ]).

-test("{active,true} {packet,4}, incomplete header").
test_active_4_incomplete_header() ->
  {ok, Port} = perl("scripts/packet", ["4-incomplete-header"], [{packet, 4}]),
  expected(Port, {active, 100}, [
    "one", "two", "three", "four",
    {error, closed}
  ]).

-test("{active,true} {packet,4}, packet too big").
test_active_4_too_big() ->
  {ok, Port} = perl("scripts/packet", ["4-too-big"],
                    [{packet, 4}, {packet_size, 40}]),
  expected(Port, {active, 100}, [
    "one", "two", "three", "four",
    {error, emsgsize}
  ]).

-test("{active,true} {packet,raw} after subprocess exited").
test_active_raw_after_exit() ->
  {ok, Port} = perl("scripts/packet", ["line"], [{packet, raw}]),
  estap:is(wait_exit(Port, 1000), {exit, 0}, "exit"),
  estap:ok(expected(Port, {active, 100}, ["one\ntwo\nthree\nfour\n", eof]),
           "output"),
  estap:all_ok().

%% }}}
%%----------------------------------------------------------------------------
%% helper functions {{{

perl(Script, Args, Options) ->
  subproc:exec(perl_path(), [estap:test_dir(Script) | Args], Options).

expected(Port, Output) ->
  expected(Port, passive, Output).

expected(Port, passive, Output) ->
  expected_recv(Port, 1, Output);
expected(Port, {active, Timeout}, Output) ->
  ok = subproc:setopts(Port, [{active, true}]),
  erlang:send_after(Timeout, self(), test_timeout),
  expected_active(Port, 1, Output);
expected(Port, {active_once, Timeout}, Output) ->
  erlang:send_after(Timeout, self(), test_timeout),
  expected_once(Port, 1, Output).

%%----------------------------------------------------------
%% expected_recv() {{{

expected_recv(_Port, _N, []) ->
  ok;
expected_recv(Port, N, [eof | Rest]) ->
  case subproc:recv(Port, 0) of
    {ok, Data} -> {error, {N, excess_data, Data}};
    eof -> expected_recv(Port, N + 1, Rest);
    {error, Reason} -> {error, {N, read_error, Reason}}
  end;
expected_recv(Port, N, [{error, ExpectedReason} | Rest]) ->
  case subproc:recv(Port, 0) of
    {ok, Data} -> {error, {N, excess_data, Data}};
    eof -> {error, {N, unexpected_eof}};
    {error, ExpectedReason} -> expected_recv(Port, N + 1, Rest);
    {error, Reason} -> {error, {N, wrong_error, Reason}}
  end;
expected_recv(Port, N, [ExpectedData | Rest]) ->
  case subproc:recv(Port, 0) of
    {ok, ExpectedData} -> expected_recv(Port, N + 1, Rest);
    {ok, Data} -> {error, {N, wrong_data, Data}};
    eof -> {error, {N, unexpected_eof}};
    {error, Reason} -> {error, {N, read_error, Reason}}
  end.

%% }}}
%%----------------------------------------------------------
%% expected_active() {{{

expected_active(_Port, _N, []) ->
  ok;
expected_active(Port, N, [timeout]) ->
  receive
    test_timeout -> ok;
    {subproc, Port, Data} -> {error, {N, excess_data, Data}};
    {subproc_closed, Port} -> {error, {N, unexpected_eof}};
    {subproc_error, Port, Reason} -> {error, {N, read_error, Reason}}
  end;
expected_active(Port, N, [eof | Rest]) ->
  receive
    test_timeout -> {error, {N, timeout}};
    {subproc, Port, Data} -> {error, {N, excess_data, Data}};
    {subproc_closed, Port} -> expected_active(Port, N + 1, Rest);
    {subproc_error, Port, Reason} -> {error, {N, read_error, Reason}}
  end;
expected_active(Port, N, [{error, ExpectedReason} | Rest]) ->
  receive
    test_timeout -> {error, {N, timeout}};
    {subproc, Port, Data} -> {error, {N, excess_data, Data}};
    {subproc_closed, Port} -> {error, {N, unexpected_eof}};
    {subproc_error, Port, ExpectedReason} -> expected_active(Port, N + 1, Rest);
    {subproc_error, Port, Reason} -> {error, {N, wrong_error, Reason}}
  end;
expected_active(Port, N, [ExpectedData | Rest]) ->
  receive
    test_timeout -> {error, {N, timeout}};
    {subproc, Port, ExpectedData} -> expected_active(Port, N + 1, Rest);
    {subproc, Port, Data} -> {error, {N, wrong_data, Data}};
    {subproc_closed, Port} -> {error, {N, unexpected_eof}};
    {subproc_error, Port, Reason} -> {error, {N, read_error, Reason}}
  end.

%% }}}
%%----------------------------------------------------------
%% expected_once() {{{

expected_once(_Port, _N, []) ->
  ok;
expected_once(Port, N, [eof | Rest]) ->
  ok = subproc:setopts(Port, [{active, once}]),
  receive
    test_timeout -> {error, {N, timeout}};
    {subproc, Port, Data} -> {error, {N, excess_data, Data}};
    {subproc_closed, Port} -> expected_once(Port, N + 1, Rest);
    {subproc_error, Port, Reason} -> {error, {N, read_error, Reason}}
  end;
expected_once(Port, N, [{error, ExpectedReason} | Rest]) ->
  ok = subproc:setopts(Port, [{active, once}]),
  receive
    test_timeout -> {error, {N, timeout}};
    {subproc, Port, Data} -> {error, {N, excess_data, Data}};
    {subproc_closed, Port} -> {error, {N, unexpected_eof}};
    {subproc_error, Port, ExpectedReason} -> expected_once(Port, N + 1, Rest);
    {subproc_error, Port, Reason} -> {error, {N, wrong_error, Reason}}
  end;
expected_once(Port, N, [ExpectedData | Rest]) ->
  ok = subproc:setopts(Port, [{active, once}]),
  receive
    test_timeout -> {error, {N, timeout}};
    {subproc, Port, ExpectedData} -> expected_once(Port, N + 1, Rest);
    {subproc, Port, Data} -> {error, {N, wrong_data, Data}};
    {subproc_closed, Port} -> {error, {N, unexpected_eof}};
    {subproc_error, Port, Reason} -> {error, {N, read_error, Reason}}
  end.

%% }}}
%%----------------------------------------------------------

wait_exit(Port, Timeout) ->
  subproc:setopts(Port, [{exit_status, true}]),
  receive
    {subproc_terminated, Port, Type, Info} ->
      {Type, Info}
  after Timeout ->
      timeout
  end.

perl_path() ->
  os:find_executable("perl").

%% }}}
%%----------------------------------------------------------------------------
%% vim:ft=erlang:foldmethod=marker
