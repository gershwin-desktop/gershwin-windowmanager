//
//  URSImageUpload.m
//  uroswm - bounded PutImage uploads
//

#import "URSImageUpload.h"

/* PutImage carries a 24-byte header. Leave extra slack so we stay clear of the
   limit regardless of how the server rounds its advertised maximum. */
static const uint64_t kURSPutImageHeaderSlack = 64;

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
                       const uint8_t *data)
{
    if (conn == NULL || data == NULL ||
        width == 0 || height == 0 || bytesPerRow == 0)
      {
        return;
      }

    /* xcb_get_maximum_request_length() returns a length in 4-byte units and
       already accounts for BIG-REQUESTS when the server supports it. */
    uint64_t maxBytes = (uint64_t)xcb_get_maximum_request_length(conn) * 4;
    uint64_t usable = (maxBytes > kURSPutImageHeaderSlack)
                        ? (maxBytes - kURSPutImageHeaderSlack)
                        : 0;

    /* Rows are never split. If even a single row will not fit we still have to
       send one at a time; the server will reject it, but banding cannot help
       and silently dropping the upload would be worse. */
    uint32_t rowsPerBand = (usable >= (uint64_t)bytesPerRow)
                             ? (uint32_t)(usable / bytesPerRow)
                             : 1;
    if (rowsPerBand == 0)
      {
        rowsPerBand = 1;
      }
    if (rowsPerBand > (uint32_t)height)
      {
        rowsPerBand = (uint32_t)height;
      }

    for (uint32_t y = 0; y < (uint32_t)height; y += rowsPerBand)
      {
        uint32_t bandHeight = (uint32_t)height - y;
        if (bandHeight > rowsPerBand)
          {
            bandHeight = rowsPerBand;
          }

        xcb_put_image(conn, format, drawable, gc,
                      width, (uint16_t)bandHeight,
                      dstX, (int16_t)(dstY + (int32_t)y),
                      leftPad, depth,
                      bandHeight * bytesPerRow,
                      data + (size_t)y * (size_t)bytesPerRow);
      }
}
