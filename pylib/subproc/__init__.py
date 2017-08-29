#!/usr/bin/python

import _unix
import struct

__all__ = [
    "Supervisor",
    "STDIO_BIDIRECTIONAL", "STDIO_IN", "STDIO_OUT", "STDIO_IN_OUT",
]

#-----------------------------------------------------------------------------

STDIO_BIDIRECTIONAL = 0
STDIO_IN     = 1
STDIO_OUT    = 2
STDIO_IN_OUT = 3

_TAG_CMD_EXEC = 0x01
_TAG_CMD_KILL = 0x02
_TAG_CMD_SHUTDOWN = 0xff

_FLAG_STDIO_MODE       = 0x03 # see also STDIO_* constants
_FLAG_STDIO_SOCKET     = 0x04
_FLAG_STDERR_TO_STDOUT = 0x08
_FLAG_PGROUP           = 0x10

#-----------------------------------------------------------------------------

class Supervisor:
    def __init__(self):
        self._sup = _unix.Supervisor()

    def __del__(self):
        self.shutdown()

    def pidof(self):
        return self._sup.pidof()

    def fileno(self):
        return self._sup.fileno()

    def run(self, command, args, env = None, termsig = 0,
            stdio_mode = STDIO_BIDIRECTIONAL, stderr_to_stdout = False,
            socket = False, pgroup = False,
            uid = None, gid = None, nice = None,
            cwd = None, argv0 = None):
        flags = stdio_mode & _FLAG_STDIO_MODE
        if socket:
            flags |= _FLAG_STDIO_SOCKET
        if stderr_to_stdout:
            flags |= _FLAG_STDERR_TO_STDOUT
        if pgroup:
            flags |= _FLAG_PGROUP
        request = bytearray()
        # header + flags
        request.extend(struct.pack(">BB", _TAG_CMD_EXEC, flags))
        # command
        request.extend(struct.pack(">H", len(command)))
        request.extend(command)
        # arguments
        request.extend(struct.pack(">H", len(args)))
        for a in args:
            request.extend(struct.pack(">H", len(a)))
            request.extend(a)
        # options
        # TODO: `if env is not None'
        request.extend(struct.pack(">BB", 0x74, termsig))
        if nice is not None:
            request.extend(struct.pack(">Bb", 0x70, nice))
        if uid is not None: # TODO: string uid
            request.extend(struct.pack(">BH", 0x75, uid))
        if gid is not None: # TODO: string gid
            request.extend(struct.pack(">BH", 0x67, gid))
        if cwd is not None:
            request.extend(struct.pack(">BH", 0x43, len(cwd)))
            request.extend(cwd)
        if argv0 is not None:
            request.extend(struct.pack(">BH", 0x30, len(argv0)))
            request.extend(argv0)
        self._command(buffer(request))

    def kill(self, id, signal = 0):
        self._command(struct.pack(">BBQ", _TAG_CMD_KILL, signal, id))

    def shutdown(self):
        self._command(struct.pack(">BB", _TAG_CMD_SHUTDOWN, 0x00))

    def _command(self, payload):
        request = bytearray(len(payload) + 4)
        struct.pack_into(">I", request, 0, len(payload))
        request[4:] = payload
        self._sup.send(buffer(request))
        # TODO: wait for reply

#-----------------------------------------------------------------------------
# vim:ft=python
