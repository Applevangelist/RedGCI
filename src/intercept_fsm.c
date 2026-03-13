#include "intercept_fsm.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

// ─────────────────────────────────────────────────────────────
//  Kontext-Verwaltung
// ─────────────────────────────────────────────────────────────

void gci_context_init(InterceptContext *ctx) {
    memset(ctx, 0, sizeof(*ctx));
    ctx->state      = STATE_VECTOR;
    ctx->prev_state = STATE_VECTOR;
    ctx->fuel_fraction = 1.0f;
}

void gci_context_update(InterceptContext *ctx,
                         float range, float aspect,
                         float closure, float alt_delta, float fuel) {
    ctx->range        = range;
    ctx->aspect_angle = aspect;
    ctx->closure_rate = closure;
    ctx->altitude_delta = alt_delta;
    ctx->fuel_fraction  = fuel;
}


// ─────────────────────────────────────────────────────────────
//  FSM Übergänge
// ─────────────────────────────────────────────────────────────

InterceptState gci_fsm_transition(const InterceptContext *ctx) {

    // Abbruch hat immer Vorrang
    if (ctx->fuel_fraction < GCI_FUEL_BINGO)
        return STATE_ABORT;
    if (ctx->threat_detected && ctx->range > GCI_RANGE_VISUAL)
        return STATE_ABORT;

    switch (ctx->state) {

        case STATE_VECTOR:
            if (ctx->range <= GCI_RANGE_COMMIT)
                return STATE_COMMIT;
            if (ctx->aspect_angle > GCI_ASPECT_NOTCH_MIN &&
                ctx->aspect_angle < GCI_ASPECT_NOTCH_MAX)
                return STATE_NOTCH;
            return STATE_VECTOR;

        case STATE_COMMIT:
            if (ctx->pilot_has_radar)
                return STATE_RADAR_CONTACT;
            if (ctx->range <= GCI_RANGE_VISUAL && !ctx->pilot_has_radar)
                return STATE_VISUAL;   // Fallback: Sichtführung
            return STATE_COMMIT;

        case STATE_RADAR_CONTACT:
            if (!ctx->pilot_has_radar)
                return STATE_COMMIT;   // Lock verloren
            if (ctx->pilot_has_visual || ctx->range <= GCI_RANGE_VISUAL)
                return STATE_VISUAL;
            return STATE_RADAR_CONTACT;

        case STATE_VISUAL:
            if (ctx->range <= GCI_RANGE_MERGE)
                return STATE_MERGE;
            return STATE_VISUAL;

        case STATE_NOTCH:
            // Warten bis Ziel normalen Aspekt hat
            if (ctx->aspect_angle < GCI_ASPECT_NOTCH_MIN ||
                ctx->aspect_angle > GCI_ASPECT_NOTCH_MAX)
                return STATE_VECTOR;
            return STATE_NOTCH;

        case STATE_MERGE:
        case STATE_ABORT:
        case STATE_RTB:
            return ctx->state;   // Terminal / handled by merge_controller
    }
    return ctx->state;
}


// ─────────────────────────────────────────────────────────────
//  Transmission Builder
// ─────────────────────────────────────────────────────────────

// Russische Himmelsrichtungsreferenz (links/rechts vom Pilot)
static const char *bearing_clock(float rel_bearing) {
    // rel_bearing: 0 = direkt vorne, 90 = rechts, 270 = links
    if (rel_bearing < 30.0f || rel_bearing > 330.0f)  return "впереди";
    if (rel_bearing < 90.0f)                           return "справа";
    if (rel_bearing < 180.0f)                          return "сзади-справа";
    if (rel_bearing < 270.0f)                          return "сзади-слева";
    return "слева";
}

// ─────────────────────────────────────────────────────────────
//  gci_build_transmission — Token-String Ausgabe (Option B)
//  Gibt strukturierte Token zurück statt Freitext.
//  Lua parst den Token-String und baut lokalisierte Strings.
//
//  Token-Format:
//    "KEY|hdg=NNN|alt=NNNN|rng=NN|tti_m=N|tti_s=NN|
//         aspect=NNN|wf=true|delay=N.N"
//
//  Keys (State → Token-Key):
//    VECTOR          → VECTOR / VECTOR_WITH_TTI
//    COMMIT (first)  → COMMIT_FIRST
//    COMMIT (nudge)  → COMMIT_NO_LOCK / COMMIT_NUDGE
//    RADAR_CONTACT   → RADAR_LOCK_WF / RADAR_LOCK_HOLD / RADAR_WF_NOW
//    VISUAL          → VISUAL_CONFIRM
//    NOTCH           → NOTCH_ENTRY / NOTCH_UPDATE
//    ABORT           → ABORT_BINGO / ABORT_THREAT
//    MERGE/RTB       → silence=true
// ─────────────────────────────────────────────────────────────

void gci_build_transmission(
    const InterceptContext  *ctx,
    const InterceptContext  *prev,
    const char              *callsign,
    const InterceptSolution *sol,
    GCITransmission         *out)
{
    memset(out, 0, sizeof(*out));
    out->silence      = false;
    out->weapons_free = sol->weapons_free;
    out->delay_sec    = GCI_CLAMP(
        gci_randf(GCI_DELAY_MIN, GCI_DELAY_MAX), 3.0f, 8.0f);

    /* Gemeinsame Werte vorberechnen */
    int hdg_i    = (int)(sol->heading_deg + 0.5f);
    int alt_i    = (int)(sol->target_alt  / 100.0f + 0.5f) * 100;
    int rng_km   = (int)(ctx->range       / 1000.0f + 0.5f);
    int aspect_i = (int)(ctx->aspect_angle + 0.5f);
    int tti_m    = (int)(sol->time_to_intercept / 60.0f);
    int tti_s    = (int)(sol->time_to_intercept) % 60;
    float delay  = out->delay_sec;

    /* Hilfsmakro: Token-String in out->token_str schreiben */
#define EMIT(fmt, ...) \
    snprintf(out->token_str, sizeof(out->token_str), fmt, ##__VA_ARGS__)

    switch (ctx->state) {

        // ── VECTOR ───────────────────────────────────────────
        case STATE_VECTOR: {
            if (prev->state != STATE_VECTOR) {
                /* Erster VECTOR-Tick: mit TTI wenn sinnvoll */
                if (tti_m > 0) {
                    EMIT("VECTOR_WITH_TTI|hdg=%d|alt=%d|rng=%d"
                         "|tti_m=%d|tti_s=%d|delay=%.1f",
                         hdg_i, alt_i, rng_km, tti_m, tti_s, delay);
                } else {
                    EMIT("VECTOR|hdg=%d|alt=%d|rng=%d|delay=%.1f",
                         hdg_i, alt_i, rng_km, delay);
                }
                break;
            }
            /* Folge-Ticks: nur bei signifikanter Kursänderung */
            float hdg_delta = fabsf(sol->heading_deg - ctx->aspect_angle);
            if (hdg_delta < 5.0f && ctx->ticks_in_state > 3) {
                out->silence = true;
            } else {
                EMIT("VECTOR|hdg=%d|alt=%d|rng=%d|delay=%.1f",
                     hdg_i, alt_i, rng_km, delay);
            }
            break;
        }

        // ── COMMIT ───────────────────────────────────────────
        case STATE_COMMIT: {
            bool first = (prev->state != STATE_COMMIT);
            if (first) {
                EMIT("COMMIT_FIRST|hdg=%d|alt=%d|rng=%d"
                     "|aspect=%d|delay=%.1f",
                     hdg_i, alt_i, rng_km, aspect_i, delay);
            } else if (ctx->ticks_in_state == 6) {
                EMIT("COMMIT_NO_LOCK|hdg=%d|rng=%d"
                     "|aspect=%d|delay=%.1f",
                     hdg_i, rng_km, aspect_i, delay);
            } else if (ctx->ticks_in_state > 8) {
                /* dir_lr wird in Lua aus aspect_angle abgeleitet */
                EMIT("COMMIT_NUDGE|hdg=%d|aspect=%d|delay=%.1f",
                     hdg_i, aspect_i, delay);
            } else {
                out->silence = true;
            }
            break;
        }

        // ── RADAR CONTACT ─────────────────────────────────────
        case STATE_RADAR_CONTACT: {
            if (prev->state != STATE_RADAR_CONTACT) {
                if (sol->weapons_free) {
                    EMIT("RADAR_LOCK_WF|rng=%d|delay=%.1f",
                         rng_km, delay);
                    out->weapons_free = true;
                } else {
                    EMIT("RADAR_LOCK_HOLD|rng=%d|delay=%.1f",
                         rng_km, delay);
                }
            } else if (!sol->weapons_free
                       && ctx->range        < GCI_WF_RANGE_MAX
                       && ctx->aspect_angle > GCI_ASPECT_REAR_ATTACK
                       && prev->state       == STATE_RADAR_CONTACT) {
                EMIT("RADAR_WF_NOW|rng=%d|delay=%.1f",
                     rng_km, delay);
                out->weapons_free = true;
            } else {
                out->silence = true;
            }
            break;
        }

        // ── VISUAL ───────────────────────────────────────────
        case STATE_VISUAL: {
            if (prev->state != STATE_VISUAL) {
                EMIT("VISUAL_CONFIRM|rng=%d|delay=%.1f",
                     rng_km, delay);
                out->weapons_free = true;
            } else {
                out->silence = true;
            }
            break;
        }

        // ── NOTCH ─────────────────────────────────────────────
        case STATE_NOTCH: {
            if (prev->state != STATE_NOTCH) {
                EMIT("NOTCH_ENTRY|rng=%d|delay=%.1f",
                     rng_km, delay);
            } else if (ctx->ticks_in_state % 8 == 0) {
                EMIT("NOTCH_UPDATE|rng=%d|aspect=%d|delay=%.1f",
                     rng_km, aspect_i, delay);
            } else {
                out->silence = true;
            }
            break;
        }

        // ── ABORT ─────────────────────────────────────────────
        case STATE_ABORT: {
            out->delay_sec = 1.5f;
            if (ctx->fuel_fraction < GCI_FUEL_BINGO) {
                EMIT("ABORT_BINGO|hdg=%d|delay=1.5", hdg_i);
            } else {
                EMIT("ABORT_THREAT|hdg=%d|delay=1.5", hdg_i);
            }
            break;
        }

        // ── MERGE / RTB / default ─────────────────────────────
        case STATE_MERGE:
        case STATE_RTB:
        default:
            out->silence = true;
            break;
    }

#undef EMIT
}
