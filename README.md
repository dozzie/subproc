Example rsync service in Erlang
===============================

`rsyncd` is a proof of concept for running [rsync](http://rsync.samba.org/)
server under control of an Erlang application. *rsync* server is exposed on
a plain TCP socket, but this can easily be changed to SSL socket.

*rsync* is spawned in *inetd* mode, which requires redirecting its
STDIN/STDOUT through a socket (`socketpair(2)`). Since Erlang doesn't have
facilities for such redirection, ports provided by `subproc` application are
used instead.


Contact and license
-------------------

`rsyncd` application is written by Stanislaw Klekot <dozzie at jarowit.net>.
The primary distribution point is <http://dozzie.jarowit.net/>.

`rsyncd` application is distributed under 3-clause BSD license. See COPYING
file for details.
