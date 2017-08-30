#!/usr/bin/python

import _unix
import struct
import os

__all__ = [
    "Supervisor",
    "SubprocError", "SubprocReqError", "SubprocOSError",
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
# exceptions {{{

class SubprocError(Exception):
    pass

class SubprocReqError(SubprocError):
    ERR_UNDEFINED      = -128 # a situation that should never happen (development error)
    ERR_PARSE          =   -1 # general request parse error
    ERR_BAD_REQ_HEADER =   -2 # invalid request packet header
    ERR_BAD_SIGNAL     =   -3 # invalid signal number
    ERR_NX_USER        =   -4 # no such user
    ERR_NX_GROUP       =   -5 # no such group
    ERR_BAD_OPTION     =   -6 # unrecognized exec option tag
    ERR_NX_CHILD       =   -7 # no such child process
    _ERROR_MESSAGES = {
        ERR_UNDEFINED:      "Development error (should never happen)",
        ERR_PARSE:          "Bad request format",
        ERR_BAD_REQ_HEADER: "Unrecognized request type",
        ERR_BAD_SIGNAL:     "Invalid signal number",
        ERR_NX_USER:        "No such user",
        ERR_NX_GROUP:       "No such group",
        ERR_BAD_OPTION:     "Unrecognized option",
        ERR_NX_CHILD:       "No such child process",
    }
    def __init__(self, code, message = None):
        if message is None:
            message = SubprocReqError._ERROR_MESSAGES.get(code, "unrecognized error code")
        super(SubprocReqError, self).__init__(code, message)
        self.code = code
        self.message = message

    def __str__(self):
        return "[Error %d] %s" % (self.code, self.message)

class SubprocOSError(SubprocError):
    def __init__(self, errno, strerror = None):
        if strerror is None:
            strerror = os.strerror(errno)
        super(SubprocOSError, self).__init__(errno, strerror)
        self.errno = errno
        self.strerror = strerror
        self.message = ""

    def __str__(self):
        return "[Errno %d] %s" % (self.errno, self.strerror)

# }}}
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
            if isinstance(uid, (int, long)):
                request.extend(struct.pack(">BH", 0x75, uid))
            else:
                request.extend(struct.pack(">BH", 0x55, len(uid)))
                request.extend(uid)
        if gid is not None:
            if isinstance(gid, (int, long)):
                request.extend(struct.pack(">BH", 0x67, gid))
            else:
                request.extend(struct.pack(">BH", 0x47, len(gid)))
                request.extend(gid)
        if cwd is not None:
            request.extend(struct.pack(">BH", 0x43, len(cwd)))
            request.extend(cwd)
        if argv0 is not None:
            request.extend(struct.pack(">BH", 0x30, len(argv0)))
            request.extend(argv0)
        return self._command(buffer(request))

    def kill(self, id, signal = 0):
        # NOTE: ignore returned `id'
        self._command(struct.pack(">BBQ", _TAG_CMD_KILL, signal, id))

    def shutdown(self):
        # NOTE: ignore returned `id'
        self._command(struct.pack(">BB", _TAG_CMD_SHUTDOWN, 0x00))

    def _command(self, payload):
        request = bytearray(len(payload) + 4)
        struct.pack_into(">I", request, 0, len(payload))
        request[4:] = payload
        (size, reply) = self._sup.send(buffer(request))
        if len(reply) != 10:
            raise SubprocError("reply too short")
        elif reply[0:2] == "\x01\x00":
            return struct.unpack(">Q", reply[2:])[0]
        elif reply[0:2] == "\x02\x01": # request error
            raise SubprocReqError(struct.unpack(">b", reply[2])[0])
        elif reply[0:2] == "\x02\x02": # OS error
            raise SubprocOSError(struct.unpack(">I", reply[2:6])[0])
        else:
            raise SubprocError("unrecognized reply")

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
