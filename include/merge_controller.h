/*
 * merge_controller.h
 * ═══════════════════════════════════════════════════════════════
 */

#ifndef MERGE_CONTROLLER_H
#define MERGE_CONTROLLER_H

#include "gci_types.h"
#include "intercept_fsm.h"  /* GCITransmission */
#include <stdbool.h>

/* ─────────────────────────────────────────────────────────────
 *  Merge-Phasen
 * ───────────────────────────────────────────────────────────── */

typedef enum {
    MERGE_ENTRY      = 0,
    MERGE_OVERSHOOT,
    MERGE_SEPARATION,
    MERGE_REATTACK,
    MERGE_LOST,
    MERGE_SPLASH,
} MergePhase;

/* ─────────────────────────────────────────────────────────────
 *  Merge-Kontext
 *  Felder aus merge_controller.c abgeleitet
 * ───────────────────────────────────────────────────────────── */

typedef struct {
    MergePhase  phase;
    int         ticks_in_phase;
    float       range;
    float       bearing_to_target;
    float       closure_rate;
    float       altitude_delta;
    int         pass_count;
    bool        radar_lost;
} MergeContext;

/* ─────────────────────────────────────────────────────────────
 *  API
 * ───────────────────────────────────────────────────────────── */

void gci_merge_context_init(MergeContext *ctx);

MergePhase gci_merge_transition(const MergeContext *ctx,
                                 const MergeContext *prev);

void gci_build_merge_transmission(const MergeContext *ctx,
                                   const MergeContext *prev,
                                   const char         *callsign,
                                   GCITransmission    *out);

#endif /* MERGE_CONTROLLER_H */
