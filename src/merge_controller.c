#include "intercept_fsm.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

void gci_merge_context_init(MergeContext *ctx) {
    memset(ctx, 0, sizeof(*ctx));
    ctx->phase = MERGE_ENTRY;
}

// ─────────────────────────────────────────────────────────────
//  Merge Phasen-Übergang
// ─────────────────────────────────────────────────────────────

MergePhase gci_merge_transition(const MergeContext *ctx,
                                  const MergeContext *prev) {
    (void)prev;

    if (ctx->radar_lost)
        return MERGE_LOST;

    if (ctx->closure_rate < -30.0f && ctx->range > 3000.0f)
        return MERGE_SEPARATION;

    if (ctx->bearing_to_target > 100.0f &&
        ctx->bearing_to_target < 260.0f &&
        ctx->range < 5000.0f)
        return MERGE_OVERSHOOT;

    if (ctx->phase == MERGE_SEPARATION && ctx->pass_count < 3)
        return MERGE_REATTACK;

    return ctx->phase;
}

// ─────────────────────────────────────────────────────────────
//  Merge Transmissions — Token-String Ausgabe
//
//  Token-Keys:
//    MERGE_ENTRY       brg, dir_rl
//    MERGE_OVERSHOOT   brg, alt_rel ("low"|"high"|"")
//    MERGE_SEPARATION  brg, rng
//    MERGE_REATTACK    brg, rng
//    MERGE_LOST        brg, rng
//    MERGE_SPLASH      (keine Parameter)
// ─────────────────────────────────────────────────────────────

void gci_build_merge_transmission(
    const MergeContext *ctx,
    const MergeContext *prev,
    const char         *callsign,
    GCITransmission    *out)
{
    (void)callsign;   /* Callsign wird in Lua eingesetzt */

    memset(out, 0, sizeof(*out));
    out->silence   = false;
    out->delay_sec = GCI_CLAMP(
        gci_randf(GCI_DELAY_MERGE_MIN, GCI_DELAY_MERGE_MAX),
        2.0f, 5.0f);

    int brg    = (int)(ctx->bearing_to_target + 0.5f);
    int rng_km = (int)(ctx->range / 1000.0f + 0.5f);
    float delay = out->delay_sec;

    /* Zielseite: bearing < 180 = rechts */
    const char *dir_rl = (ctx->bearing_to_target < 180.0f)
                         ? "right" : "left";

    /* Höhenrelation für OVERSHOOT */
    const char *alt_rel = "";
    if      (ctx->altitude_delta >  400.0f) alt_rel = "low";
    else if (ctx->altitude_delta < -400.0f) alt_rel = "high";

#define EMIT(fmt, ...) \
    snprintf(out->token_str, sizeof(out->token_str), fmt, ##__VA_ARGS__)

    switch (ctx->phase) {

        case MERGE_ENTRY: {
            EMIT("MERGE_ENTRY|brg=%d|dir_rl=%s|delay=%.1f",
                 brg, dir_rl, delay);
            break;
        }

        case MERGE_OVERSHOOT: {
            EMIT("MERGE_OVERSHOOT|brg=%d|dir_rl=%s|alt_rel=%s|delay=%.1f",
                 brg, dir_rl, alt_rel, delay);
            break;
        }

        case MERGE_SEPARATION: {
            if (ctx->pass_count < 3) {
                EMIT("MERGE_REATTACK|brg=%d|rng=%d|delay=%.1f",
                     brg, rng_km, delay);
            } else {
                EMIT("ABORT_THREAT|hdg=%d|delay=%.1f",
                     brg, delay);
            }
            break;
        }

        case MERGE_REATTACK: {
            if (prev->phase != MERGE_REATTACK) {
                EMIT("MERGE_REATTACK|brg=%d|rng=%d|delay=%.1f",
                     brg, rng_km, delay);
            } else if (ctx->ticks_in_phase % 3 == 0) {
                EMIT("MERGE_REATTACK|brg=%d|rng=%d|delay=%.1f",
                     brg, rng_km, delay);
            } else {
                out->silence = true;
            }
            break;
        }

        case MERGE_LOST: {
            if (prev->phase != MERGE_LOST) {
                EMIT("MERGE_LOST|brg=%d|rng=%d|delay=%.1f",
                     brg, rng_km, delay);
            } else if (ctx->ticks_in_phase == 4) {
                EMIT("MERGE_LOST|brg=%d|rng=%d|delay=%.1f",
                     brg, rng_km, delay);
            } else {
                out->silence = true;
            }
            break;
        }

        case MERGE_SPLASH: {
            out->delay_sec = 1.5f;
            EMIT("MERGE_SPLASH|delay=1.5");
            break;
        }
    }

#undef EMIT
}
