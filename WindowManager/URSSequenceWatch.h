/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <xcb/xcb.h>

/* libxcb widens the 16-bit sequence number of every packet against the one
 * read before it.  A packet that lands beyond the last request this
 * connection sent moves libxcb past requests that have not been answered
 * yet: from then on every reply comes back NULL without an error, nothing is
 * reparented and nothing is logged (seen on FreeBSD CI only).  The first
 * report showed the lead had grown in steps too small for a check on big
 * jumps alone, so the count is compared whenever the packets pass another
 * 1024 requests, the packets before are kept to be named, and a request that
 * must fail tells whether the server itself counts differently (its error
 * carries the server's own 16-bit number for it). */

#define URS_SEQUENCE_HISTORY 32

typedef struct {
    uint8_t responseType;
    uint8_t detail;
    uint16_t sequence;
    uint32_t fullSequence;
} URSPacketRecord;

typedef struct {
    uint32_t lastFullSequence;
    unsigned reports;
    URSPacketRecord history[URS_SEQUENCE_HISTORY];
    unsigned historyCount;
    BOOL probePending;
    uint16_t probeSequence;
    int16_t probeDifference;
    unsigned errorsLogged;
} URSSequenceWatch;

typedef NS_ENUM(NSInteger, URSSequenceWatchResult) {
    URSSequenceWatchNothing,
    // The packet is numbered beyond the last request sent.
    URSSequenceWatchOverrun,
    // The error of the probe request came back; see probeDifference.
    URSSequenceWatchProbeAnswered,
};

URSSequenceWatchResult URSSequenceWatchPacket(URSSequenceWatch *watch,
                                              xcb_connection_t *connection,
                                              xcb_generic_event_t *packet);
