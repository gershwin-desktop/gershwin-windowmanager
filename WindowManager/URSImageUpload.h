//
//  URSImageUpload.h
//  uroswm - bounded PutImage uploads
//
//  A single PutImage request may not exceed the maximum request length the X
//  server advertises. libxcb does not split oversized requests: it refuses to
//  send them and shuts the connection down with XCB_CONN_CLOSED_REQ_LEN_EXCEED.
//
//  A full-screen 32-bit image is 33MB at 3840x2160, against a typical 16MB
//  ceiling, so any upload sized from screen or window geometry must be banded.
//

#ifndef URS_IMAGE_UPLOAD_H
#define URS_IMAGE_UPLOAD_H

#include <xcb/xcb.h>
#include <stdint.h>

/**
 * Upload image data with xcb_put_image(), split into horizontal bands so that
 * no single request exceeds the server's maximum request length.
 *
 * Rows are never split, so bytesPerRow must describe tightly-packed rows of
 * the same layout xcb_put_image() expects (for Z_PIXMAP at depth 24/32 that
 * is width * 4).
 *
 * @param bytesPerRow  Stride of one packed row, in bytes.
 * @param data         Pixel data, height * bytesPerRow bytes long.
 */
void URSPutImageBanded(xcb_connection_t *conn,
                       uint8_t format,
                       xcb_drawable_t drawable,
                       xcb_gcontext_t gc,
                       uint16_t width,
                       uint16_t height,
                       int16_t dstX,
                       int16_t dstY,
                       uint8_t leftPad,
                       uint8_t depth,
                       uint32_t bytesPerRow,
                       const uint8_t *data);

#endif /* URS_IMAGE_UPLOAD_H */
