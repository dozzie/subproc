//----------------------------------------------------------------------------

#include <string.h>

#include "proto_event.h"
#include "int_pack.h"

//----------------------------------------------------------------------------

int parse_event(void *buffer, struct event_t *event)
{
  memset(event, 0, sizeof(struct event_t));
  unsigned char *rbuf = buffer;

  if (rbuf[0] == 0x73) {
    event->type = event_spawn;
    event->spawn.stdio_mode = rbuf[1]; // TODO: check value
    event->id = unpack64(rbuf + 2);
    event->spawn.pid = unpack32(rbuf + 10);
  } else if (rbuf[0] == 0x65) {
    event->type = event_spawn_error;
    event->error.stage = rbuf[1];
    event->id = unpack64(rbuf + 2);
    event->error.error = unpack32(rbuf + 10);
  } else if (rbuf[0] == 0x78) {
    event->type = event_exit;
    //rbuf[1] == 0; not used
    event->id = unpack64(rbuf + 2);
    event->exit_code = unpack32(rbuf + 10);
  } else if (rbuf[0] == 0x6b) {
    event->type = event_signal;
    //rbuf[1] == 0; not used
    event->id = unpack64(rbuf + 2);
    event->signal = unpack32(rbuf + 10); // TODO: check signal value
  } else {
    return -1;
  }

  return 0;
}

void build_event(void *buffer, struct event_t *event)
{
  unsigned char *wbuf = buffer;

  if (event->type == event_spawn) {
    wbuf[0] = 0x73;
    wbuf[1] = event->spawn.stdio_mode;
    store64(wbuf + 2, event->id);
    store32(wbuf + 10, event->spawn.pid);
  } else if (event->type == event_spawn_error) {
    wbuf[0] = 0x65;
    wbuf[1] = event->error.stage;
    store64(wbuf + 2, event->id);
    store32(wbuf + 10, event->error.error);
  } else if (event->type == event_exit) {
    wbuf[0] = 0x78;
    wbuf[1] = 0;
    store64(wbuf + 2, event->id);
    store32(wbuf + 10, event->exit_code);
  } else if (event->type == event_signal) {
    wbuf[0] = 0x6b;
    wbuf[1] = 0;
    store64(wbuf + 2, event->id);
    store32(wbuf + 10, event->signal);
  }
}

//----------------------------------------------------------------------------
// vim:ft=c:foldmethod=marker
