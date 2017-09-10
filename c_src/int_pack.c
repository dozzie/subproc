//----------------------------------------------------------------------------

#include "int_pack.h"

//----------------------------------------------------------------------------

uint16_t unpack16(unsigned char *buf)
{
  return (uint32_t)buf[0] << (8 * 1)
       | (uint32_t)buf[1] << (8 * 0);
}

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

//----------------------------------------------------------------------------

void store16(unsigned char *buf, uint16_t value)
{
  buf[0] = 0xff & (value >> (8 * 1));
  buf[1] = 0xff & (value >> (8 * 0));
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
// vim:ft=c
