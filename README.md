Unix subprocess manager for Erlang
==================================

`subproc` is a unix subprocess manager for Erlang. It works much closer with
operating systems than Erlang, so over built-in ports it provides several
advantages:

* tracks subprocess' PID
* can spawn a subprocess in a process group
* can send a signal to a subprocess or its process group
* subprocess' STDIO can be redirected with `pipe(2)` or `socketpair(2)`
* spawned port can work in `{active,once}` and passive modes known from
  `gen_tcp` and other socket modules, which provides a sensible backpressure
  to external command (running `yes` won't trigger OOM killer)

`subproc` can also spawn ports from already-opened descriptors, which is
mainly intended for reading from STDIN with backpressure.

Prior art
---------

[`erlexec`](https://github.com/saleyn/erlexec) application is somewhat
similar, though it has different goals. It allows to treat OS processes as
Erlang processes, including setting links and monitors. `subproc`, on the
other hand, focuses on handling processes in a manner similar to network
sockets, and unix-specific features (`pipe()`/`socketpair()`, process groups,
signals), although important, are auxiliary.

Contact and license
-------------------

`subproc` library is written by Stanislaw Klekot <dozzie at jarowit.net>.
The primary distribution point is <http://dozzie.jarowit.net/>.

`subproc` library is distributed under 3-clause BSD license. See COPYING file
for details.
