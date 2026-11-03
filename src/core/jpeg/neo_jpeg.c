/* See neo_jpeg.h. The compressor is created once and reused, so libjpeg's
 * permanent pools are not rebuilt on every screenshot. */
#include "neo_jpeg.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jpeglib.h"

struct neo_jpeg {
  struct jpeg_compress_struct cinfo;
  struct jpeg_error_mgr err;
  struct jpeg_destination_mgr dest;
  jmp_buf jump;
  unsigned char *out;
  size_t cap;
  int overflow;
  char message[JMSG_LENGTH_MAX];
};

static void on_error(j_common_ptr cinfo) {
  neo_jpeg *enc = (neo_jpeg *)cinfo->client_data;
  cinfo->err->format_message(cinfo, enc->message);
  longjmp(enc->jump, 1);
}

static void on_message(j_common_ptr cinfo) { (void)cinfo; /* never print */ }

static void dest_init(j_compress_ptr cinfo) {
  neo_jpeg *enc = (neo_jpeg *)cinfo->client_data;
  enc->dest.next_output_byte = enc->out;
  enc->dest.free_in_buffer = enc->cap;
}

static boolean dest_empty(j_compress_ptr cinfo) {
  neo_jpeg *enc = (neo_jpeg *)cinfo->client_data;
  enc->overflow = 1;
  longjmp(enc->jump, 1);
  return FALSE;
}

static void dest_term(j_compress_ptr cinfo) { (void)cinfo; }

neo_jpeg *neo_jpeg_create(void) {
  neo_jpeg *enc = (neo_jpeg *)calloc(1, sizeof(neo_jpeg));
  if (!enc) return NULL;
  enc->cinfo.err = jpeg_std_error(&enc->err);
  enc->err.error_exit = on_error;
  enc->err.output_message = on_message;
  enc->cinfo.client_data = enc;
  if (setjmp(enc->jump)) {
    free(enc);
    return NULL;
  }
  jpeg_create_compress(&enc->cinfo);
  enc->dest.init_destination = dest_init;
  enc->dest.empty_output_buffer = dest_empty;
  enc->dest.term_destination = dest_term;
  enc->cinfo.dest = &enc->dest;
  return enc;
}

void neo_jpeg_destroy(neo_jpeg *enc) {
  if (!enc) return;
  jpeg_destroy_compress(&enc->cinfo);
  free(enc);
}

int neo_jpeg_encode_bgra(neo_jpeg *enc, const unsigned char *bgra, unsigned width, unsigned height,
                         size_t stride, int quality, unsigned char *out, size_t out_cap, size_t *out_len) {
  /* volatile: read after longjmp */
  volatile int status = NEO_JPEG_OK;
  enc->out = out;
  enc->cap = out_cap;
  enc->overflow = 0;
  enc->message[0] = 0;
  if (setjmp(enc->jump)) {
    status = enc->overflow ? NEO_JPEG_OVERFLOW : NEO_JPEG_FAILED;
    jpeg_abort_compress(&enc->cinfo);
    return status;
  }
  enc->cinfo.image_width = width;
  enc->cinfo.image_height = height;
  enc->cinfo.input_components = 4;
  enc->cinfo.in_color_space = JCS_EXT_BGRA;
  jpeg_set_defaults(&enc->cinfo);
  jpeg_set_quality(&enc->cinfo, quality, TRUE);
  enc->cinfo.dct_method = JDCT_ISLOW;
  jpeg_start_compress(&enc->cinfo, TRUE);
  while (enc->cinfo.next_scanline < enc->cinfo.image_height) {
    JSAMPROW rows[16];
    unsigned first = enc->cinfo.next_scanline;
    unsigned n = enc->cinfo.image_height - first;
    if (n > 16) n = 16;
    for (unsigned i = 0; i < n; i++) rows[i] = (JSAMPROW)(bgra + (size_t)(first + i) * stride);
    jpeg_write_scanlines(&enc->cinfo, rows, n);
  }
  jpeg_finish_compress(&enc->cinfo);
  *out_len = enc->cap - enc->dest.free_in_buffer;
  return status;
}

const char *neo_jpeg_last_error(const neo_jpeg *enc) { return enc->message; }
