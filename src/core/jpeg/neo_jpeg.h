/* Thin libjpeg-turbo wrapper for the screenshot pipeline. libjpeg reports
 * errors through longjmp, which Zig cannot catch; this shim keeps the
 * setjmp on the C side and returns status codes. */
#ifndef NEO_JPEG_H
#define NEO_JPEG_H

#include <stddef.h>

typedef struct neo_jpeg neo_jpeg;

/* Status codes. */
#define NEO_JPEG_OK 0
#define NEO_JPEG_OVERFLOW 1 /* output buffer too small: retry larger */
#define NEO_JPEG_FAILED 2

/* A reusable compressor (NULL when out of memory). */
neo_jpeg *neo_jpeg_create(void);
void neo_jpeg_destroy(neo_jpeg *enc);

/* Encodes a top-down BGRA image (rows `stride` bytes apart) at `quality`
 * into out[0..out_cap). Writes the encoded size to *out_len on success. */
int neo_jpeg_encode_bgra(neo_jpeg *enc, const unsigned char *bgra, unsigned width, unsigned height,
                         size_t stride, int quality, unsigned char *out, size_t out_cap, size_t *out_len);

/* libjpeg's message for the last NEO_JPEG_FAILED. */
const char *neo_jpeg_last_error(const neo_jpeg *enc);

#endif
