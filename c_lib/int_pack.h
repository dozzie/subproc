#ifndef __INT_PACK_H
#define __INT_PACK_H

#include <stdint.h>

uint16_t unpack16(unsigned char *buf);
uint32_t unpack32(unsigned char *buf);
uint64_t unpack64(unsigned char *buf);

void store16(unsigned char *buf, uint16_t value);
void store32(unsigned char *buf, uint32_t value);
void store64(unsigned char *buf, uint64_t value);

#endif // __INT_PACK_H
