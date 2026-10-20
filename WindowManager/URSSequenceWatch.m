/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSequenceWatch.h"

static void URSLogHistory(URSSequenceWatch *watch)
{
    unsigned n = MIN(watch->historyCount, (unsigned)URS_SEQUENCE_HISTORY);
    for (unsigned i = 0; i < n; i++) {
        URSPacketRecord *r =
            &watch->history[(watch->historyCount - n + i) % URS_SEQUENCE_HISTORY];
        NSLog(@"[WindowManager] XCB packet before the overrun: type %u (raw %u, "
              @"byte 1 %u) sequence %u widened %u",
              r->responseType & 0x7f, r->responseType, r->detail,
              r->sequence, r->fullSequence);
    }
}

URSSequenceWatchResult URSSequenceWatchPacket(URSSequenceWatch *watch,
                                              xcb_connection_t *c,
                                              xcb_generic_event_t *e)
{
    uint8_t type = e->response_type & 0x7f;
    if (type == XCB_KEYMAP_NOTIFY) {
        return URSSequenceWatchNothing;
    }

    if (type == 0 && watch->reports > 0) {
        xcb_generic_error_t *error = (xcb_generic_error_t *)e;
        if (watch->probePending && error->major_code == XCB_FREE_PIXMAP &&
            error->resource_id == 0) {
            watch->probePending = NO;
            watch->probeDifference = (int16_t)(error->sequence - watch->probeSequence);
            NSLog(@"[WindowManager] XCB sequence probe: the server numbered request %u "
                  @"as %u (16 bits), a difference of %d",
                  watch->probeSequence, error->sequence, watch->probeDifference);
            return URSSequenceWatchProbeAnswered;
        }
        if (watch->errorsLogged < 100) {
            watch->errorsLogged++;
            NSLog(@"[WindowManager] X error after the overrun: code %u major %u minor %u "
                  @"value %u sequence %u (widened %u)",
                  error->error_code, error->major_code, error->minor_code,
                  error->resource_id, error->sequence, error->full_sequence);
        }
    }

    URSPacketRecord *record =
        &watch->history[watch->historyCount++ % URS_SEQUENCE_HISTORY];
    record->responseType = e->response_type;
    record->detail = ((uint8_t *)e)[1];
    record->sequence = e->sequence;
    record->fullSequence = e->full_sequence;

    uint32_t previous = watch->lastFullSequence;
    watch->lastFullSequence = e->full_sequence;
    // Asking the connection for its own count costs a request, so it is done
    // only when the packets have moved on by another 1024.
    if (previous == 0 || watch->reports >= 20 ||
        ((e->full_sequence >> 10) == (previous >> 10) &&
         e->full_sequence - previous < 0x400)) {
        return URSSequenceWatchNothing;
    }
    uint32_t sent = xcb_no_operation(c).sequence;
    if ((int32_t)(e->full_sequence - sent) <= 0) {
        return URSSequenceWatchNothing;
    }
    watch->reports++;
    NSLog(@"[WindowManager] XCB sequence overrun: event type %u (raw %u, "
          @"16-bit sequence %u) widened to %u, previous event %u, last request "
          @"sent %u; replies to the requests in between come back empty",
          type, e->response_type, e->sequence, e->full_sequence, previous, sent);
    if (watch->reports == 1) {
        URSLogHistory(watch);
        // Pixmap 0 never exists: the BadPixmap error comes back with the
        // number the server gave this request.
        watch->probeSequence = (uint16_t)xcb_free_pixmap(c, 0).sequence;
        watch->probePending = YES;
        xcb_flush(c);
    }
    return URSSequenceWatchOverrun;
}
