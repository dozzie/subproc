//----------------------------------------------------------------------------

#include <Python.h>

#include <string.h>
#include <errno.h>

//----------------------------------------------------------------------------

#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>

//----------------------------------------------------------------------------

#define PACKAGE_NAME "subproc"
#define MODULE_NAME "_unix"
#define TYPE_NAME   "Supervisor"

#define MODULE_DOCSTRING "Subprocess supervisor module."
#define TYPE_DOCSTRING   "Subprocess supervisor."

//----------------------------------------------------------------------------

// struct for object instance
typedef struct {
  PyObject_HEAD
  pid_t supervisor;
  int fd;
} ObjectInstance;

//----------------------------------------------------------------------------
// __init__()/__del__() {{{
// well, sort of

static
int obj_init(ObjectInstance *self, PyObject *args, PyObject *kwargs)
{
  self->supervisor = -1;
  self->fd = -1;

  // TODO: self->stuff = initialize(); if pipe/fork fail, return -1

  return 0;
}

static
void obj_dealloc(ObjectInstance *self)
{
  if (self->fd >= 0) {
    close(self->fd);
    self->fd = -1;
  }
  if (self->supervisor > 0) { // NOTE: PID will never have the value of 0
    waitpid(self->supervisor, NULL, 0);
    self->supervisor = -1;
  }

  self->ob_type->tp_free((PyObject *)self);
}

// }}}
//----------------------------------------------------------------------------
// object methods {{{

static
PyObject* supervisor_send(ObjectInstance *self, PyObject *args)
{
  // TODO
  Py_INCREF(Py_None);
  return Py_None;
}

static
PyObject* supervisor_recv(ObjectInstance *self, PyObject *args)
{
  // TODO
  Py_INCREF(Py_None);
  return Py_None;
}

static
PyObject* supervisor_fileno(ObjectInstance *self, PyObject *args)
{
  if (self->fd < 0) {
    // uninitialized object
    Py_INCREF(Py_None);
    return Py_None;
  }
  return Py_BuildValue("i", self->fd);
}

// }}}
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// Python module administrative stuff
//----------------------------------------------------------------------------
// static variables {{{

// methods for Supervisor instance
static
PyMethodDef object_methods[] = {
  {"send", (PyCFunction)supervisor_send, METH_VARARGS,
    "send a binary message"},
  {"recv", (PyCFunction)supervisor_recv, METH_VARARGS,
    "receive a binary event"},
  {"fileno", (PyCFunction)supervisor_fileno, METH_VARARGS,
    "return events' file descriptor"},
  {NULL}  /* sentinel */
};

// struct for object instance's class
static
PyTypeObject TypeObject = {
  PyObject_HEAD_INIT(NULL)
  0,                         /* ob_size           */
  PACKAGE_NAME "." MODULE_NAME "." TYPE_NAME, /* tp_name */
  sizeof(ObjectInstance),    /* tp_basicsize      */
  0,                         /* tp_itemsize       */
  (destructor)obj_dealloc,   /* tp_dealloc        */
  0,                         /* tp_print          */
  0,                         /* tp_getattr        */
  0,                         /* tp_setattr        */
  0,                         /* tp_compare        */
  0,                         /* tp_repr           */
  0,                         /* tp_as_number      */
  0,                         /* tp_as_sequence    */
  0,                         /* tp_as_mapping     */
  0,                         /* tp_hash           */
  0,                         /* tp_call           */
  0,                         /* tp_str            */
  0,                         /* tp_getattro       */
  0,                         /* tp_setattro       */
  0,                         /* tp_as_buffer      */
  Py_TPFLAGS_DEFAULT,        /* tp_flags          */
  TYPE_DOCSTRING,            /* tp_doc            */
  0,		                     /* tp_traverse       */
  0,		                     /* tp_clear          */
  0,		                     /* tp_richcompare    */
  0,		                     /* tp_weaklistoffset */
  0,		                     /* tp_iter           */
  0,		                     /* tp_iternext       */
  object_methods,            /* tp_methods        */
  0,                         /* tp_members        */
  0,                         /* tp_getset         */
  0,                         /* tp_base           */
  0,                         /* tp_dict           */
  0,                         /* tp_descr_get      */
  0,                         /* tp_descr_set      */
  0,                         /* tp_dictoffset     */
  (initproc)obj_init,        /* tp_init           */
};

// }}}
//----------------------------------------------------------------------------
// module initializer {{{

#ifndef PyMODINIT_FUNC	/* declarations for DLL import/export */
#define PyMODINIT_FUNC void
#endif

// XXX: module entry point needs to have "init_unix" name
PyMODINIT_FUNC init_unix(void)
{
  PyObject* module;

  TypeObject.tp_new = PyType_GenericNew;
  if (PyType_Ready(&TypeObject) < 0)
    return;

  module = Py_InitModule3(MODULE_NAME, object_methods, MODULE_DOCSTRING);

  Py_INCREF(&TypeObject);
  PyModule_AddObject(module, TYPE_NAME, (PyObject *)&TypeObject);
}

// }}}
//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
