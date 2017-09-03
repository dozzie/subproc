Unix subprocess manager for Erlang
==================================

**NOTE**: This repository contains a *prototype* for backend mechanism. As
such, user-facing interface was written in Python.

`subproc` is a unix subprocess manager for Erlang. It works much closer with
operating systems than Erlang, so over built-in ports it provides several
advantages:

* tracks subprocess' PID
* can spawn a subprocess in a process group
* can send a signal to a subprocess or its process group
* subprocess' STDIO can be intercepted with `pipe(2)` or `socketpair(2)`
* spawned port can work in `{active,once}` and passive modes known from
  `gen_tcp` and other socket modules, which provides a sensible backpressure
  to external command (running `yes` won't trigger OOM killer)

Contact and License
-------------------

`subproc` library is written by Stanislaw Klekot <dozzie at jarowit.net>.
The primary distribution point is <http://dozzie.jarowit.net/>.

`subproc` library is distributed under 3-clause BSD license. See COPYING file
for details.
