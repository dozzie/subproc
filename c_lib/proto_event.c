//----------------------------------------------------------------------------

#include <string.h>

#include "proto_event.h"

//----------------------------------------------------------------------------

uint32_t unpack32(unsigned char *buf)
{
  return (uint32_t)buf[0] << (8 * 3)
       | (uint32_t)buf[1] << (8 * 2)
       | (uint32_t)buf[2] << (8 * 1)
       | (uint32_t)buf[3] << (8 * 0);
}

uint64_t unpack64(unsigned char *buf)
{
  return (uint64_t)buf[0] << (8 * 7)
       | (uint64_t)buf[1] << (8 * 6)
       | (uint64_t)buf[2] << (8 * 5)
       | (uint64_t)buf[3] << (8 * 4)
       | (uint64_t)buf[4] << (8 * 3)
       | (uint64_t)buf[5] << (8 * 2)
       | (uint64_t)buf[6] << (8 * 1)
       | (uint64_t)buf[7] << (8 * 0);
}

void store32(unsigned char *buf, uint32_t value)
{
  buf[0] = 0xff & (value >> (8 * 3));
  buf[1] = 0xff & (value >> (8 * 2));
  buf[2] = 0xff & (value >> (8 * 1));
  buf[3] = 0xff & (value >> (8 * 0));
}

void store64(unsigned char *buf, uint64_t value)
{
  buf[0] = 0xff & (value >> (8 * 7));
  buf[1] = 0xff & (value >> (8 * 6));
  buf[2] = 0xff & (value >> (8 * 5));
  buf[3] = 0xff & (value >> (8 * 4));
  buf[4] = 0xff & (value >> (8 * 3));
  buf[5] = 0xff & (value >> (8 * 2));
  buf[6] = 0xff & (value >> (8 * 1));
  buf[7] = 0xff & (value >> (8 * 0));
}

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
