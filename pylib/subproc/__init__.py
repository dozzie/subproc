#!/usr/bin/python

import _unix
import struct
import os

__all__ = [
    "Supervisor",
    "Child", "SpawnError", "ChildExit", "ChildSignal",
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
    ERR_CHILD_SPACE    = -127 # no more space for registering children
    ERR_PARSE          =   -1 # general request parse error
    ERR_BAD_REQ_HEADER =   -2 # invalid request packet header
    ERR_BAD_SIGNAL     =   -3 # invalid signal number
    ERR_BAD_STDIO      =   -4 # bidirectional STDIO requested for pipe
    ERR_NX_USER        =   -5 # no such user
    ERR_NX_GROUP       =   -6 # no such group
    ERR_BAD_OPTION     =   -7 # unrecognized exec option tag
    ERR_NX_CHILD       =   -8 # no such child process
    _ERROR_MESSAGES = {
        ERR_UNDEFINED:      "Development error (should never happen)",
        ERR_CHILD_SPACE:    "No more space for registering children",
        ERR_PARSE:          "Bad request format",
        ERR_BAD_REQ_HEADER: "Unrecognized request type",
        ERR_BAD_SIGNAL:     "Invalid signal number",
        ERR_BAD_STDIO:      "Bidirectional STDIO requested for pipe",
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
# events {{{

class Child:
    @staticmethod
    def fdopen(fd, mode):
        if fd is not None:
            return os.fdopen(fd, mode)
        return None

    def __init__(self, cid, pid, child_in, child_out):
        self.id = cid
        self.pid = pid
        self.child_in = Child.fdopen(child_in, "w")
        self.child_out = Child.fdopen(child_out, "r")

    def __repr__(self):
        if self.child_in is None and self.child_out is not None:
            mode = "r"
        elif self.child_in is not None and self.child_out is None:
            mode = "w"
        else: # at least one is non-empty
            if self.child_in == self.child_out:
                mode = "b"
            else:
                mode = "rw"
        return "<Child ID=%d PID=%d MODE=%s>" % (self.id, self.pid, mode)

class SpawnError:
    _STAGES = {
        0: "socketpair(confirm)",
        1: "pipe(stdin)",
        2: "pipe(stdout)",
        3: "socketpair(stdin)",
        4: "socketpair(stdout)",
        5: "fork()",
        6: "setpriority()",
        7: "setgid()",
        8: "setuid()",
        9: "chdir()",
        10: "exec()",
    }

    def __init__(self, cid, stage, errno):
        self.id = cid
        self.errno = errno
        self.stage = stage
        self.strerror = os.strerror(errno)
        self.strstage = SpawnError._STAGES.get(stage, "<unrecognized>")

    def __repr__(self):
        return "<SpawnError ID=%d %s=%d [%s]>" % (
            self.id, self.strstage, self.errno, self.strerror
        )

class ChildExit:
    def __init__(self, cid, code):
        self.id = cid
        self.exit_code = code

    def __repr__(self):
        return "<ChildExit ID=%d exit(%d)>" % (self.id, self.exit_code)

class ChildSignal:
    def __init__(self, cid, signal):
        self.id = cid
        self.signal = signal

    def __repr__(self):
        return "<ChildExit ID=%d kill(%d)>" % (self.id, self.signal)

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

    def recv(self):
        event = self._sup.recv()
        if event is None:
            return None
        # XXX: all events have the same structure, only meaning of two of the
        # fields is different
        (evtype, mod, child_id, data) = struct.unpack(">BBQI", event[0])
        if evtype == 0x73: # <spawn>
            if mod == 0:
                child_in  = event[1][0]
                child_out = event[1][0]
            elif mod == 1:
                child_in  = event[1][0]
                child_out = None
            elif mod == 2:
                child_in  = None
                child_out = event[1][0]
            elif mod == 3:
                child_in  = event[1][0]
                child_out = event[1][1]
            else:
                raise Exception("unrecognized STDIO mode")
            return Child(cid = child_id, pid = data,
                         child_in = child_in, child_out = child_out)
        elif evtype == 0x65: # <spawn error>
            return SpawnError(cid = child_id, stage = mod, errno = data)
        elif evtype == 0x78: # <child exited>
            return ChildExit(cid = child_id, code = data)
        elif evtype == 0x6b: # <child killed>
            return ChildSignal(cid = child_id, signal = data)
        else:
            raise Exception("unrecognized event")

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
