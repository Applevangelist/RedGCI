#ifndef INTERCEPT_FSM_H
#define INTERCEPT_FSM_H

#include "gci_types.h"

// FSM Übergang berechnen
InterceptState gci_fsm_transition(const InterceptContext *ctx);

// GCI-Transmission für aktuellen Zustand generieren
void gci_build_transmission(
    const InterceptContext *ctx,
    const InterceptContext *prev,
    const char             *callsign,
    const InterceptSolution *sol,
    GCITransmission        *out
);

// Kontext initialisieren
void gci_context_init(InterceptContext *ctx);

// Kontext mit neuen Messwerten aktualisieren
void gci_context_update(
    InterceptContext  *ctx,
    float              range,
    float              aspect,
    float              closure,
    float              alt_delta,
    float              fuel
);

#endif


#ifndef MERGE_CONTROLLER_H
#define MERGE_CONTROLLER_H

#include "gci_types.h"

// Merge-Phase bestimmen
MergePhase gci_merge_transition(
    const MergeContext *ctx,
    const MergeContext *prev
);

// Merge-Transmission generieren
void gci_build_merge_transmission(
    const MergeContext *ctx,
    const MergeContext *prev,
    const char         *callsign,
    GCITransmission    *out
);

void gci_merge_context_init(MergeContext *ctx);

#endif
