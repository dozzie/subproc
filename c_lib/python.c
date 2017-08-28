//----------------------------------------------------------------------------

#include <Python.h>

#include "supervisor.h"

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
  struct sup_h sup;
} ObjectInstance;

//----------------------------------------------------------------------------
// __init__()/__del__() {{{
// well, sort of

static
int obj_init(ObjectInstance *self, PyObject *args, PyObject *kwargs)
{
  if (supervisor_spawn(&self->sup) < 0) {
    PyErr_SetFromErrno(PyExc_OSError);
    return -1;
  }

  return 0;
}

static
void obj_dealloc(ObjectInstance *self)
{
  supervisor_terminate(&self->sup);
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
  char buffer[1024];
  size_t bufsize = 1024;
  int fds[16];
  size_t fdnum = 16;
  int result = supervisor_read_event(&self->sup, buffer, &bufsize, fds, &fdnum);

  if (result < 0) {
    PyErr_SetFromErrno(PyExc_OSError);
    return NULL;
  }

  if (result == 0) {
    Py_INCREF(Py_None);
    return Py_None;
  }

  if (fdnum == 0)
    return Py_BuildValue("s#O", buffer, bufsize, Py_None);
  // else: fdnum > 0

  PyObject *pyfds = PyList_New(fdnum);
  if (pyfds == NULL)
    return NULL;

  int i;
  for (i = 0; i < fdnum; ++i) {
    PyObject *num = PyInt_FromLong(fds[i]);
    if (num == NULL) {
      Py_DECREF(pyfds);
      return NULL;
    }
    PyList_SET_ITEM(pyfds, i, num);
  }

  PyObject *res = Py_BuildValue("s#O", buffer, bufsize, pyfds);
  Py_DECREF(pyfds);
  return res;
}

static
PyObject* supervisor_fileno(ObjectInstance *self, PyObject *args)
{
  if (self->sup.events < 0) {
    // uninitialized object
    Py_INCREF(Py_None);
    return Py_None;
  }
  return Py_BuildValue("i", self->sup.events);
}

static
PyObject* supervisor_pidof(ObjectInstance *self, PyObject *args)
{
  if (self->sup.pid < 0) {
    // uninitialized object
    Py_INCREF(Py_None);
    return Py_None;
  }
  return Py_BuildValue("i", self->sup.pid);
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
    "return supervisor's events file descriptor"},
  {"pidof", (PyCFunction)supervisor_pidof, METH_VARARGS,
    "return supervisor's PID"},
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
