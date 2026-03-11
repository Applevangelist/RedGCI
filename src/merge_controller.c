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

    // Separation: beide fliegen auseinander
    if (ctx->closure_rate < -30.0f && ctx->range > 3000.0f)
        return MERGE_SEPARATION;

    // Überschuss: Jäger hat überschossen (Ziel jetzt hinter ihm)
    // bearing_to_target > 90° und < 270° → Ziel hinter uns
    if (ctx->bearing_to_target > 100.0f &&
        ctx->bearing_to_target < 260.0f &&
        ctx->range < 5000.0f)
        return MERGE_OVERSHOOT;

    if (ctx->phase == MERGE_SEPARATION && ctx->pass_count < 3)
        return MERGE_REATTACK;

    return ctx->phase;
}


// ─────────────────────────────────────────────────────────────
//  Merge Transmissions
// ─────────────────────────────────────────────────────────────

void gci_build_merge_transmission(
    const MergeContext *ctx,
    const MergeContext *prev,
    const char         *callsign,
    GCITransmission    *out)
{
    memset(out, 0, sizeof(*out));
    out->silence   = false;
    out->delay_sec = GCI_CLAMP(
        gci_randf(GCI_DELAY_MERGE_MIN, GCI_DELAY_MERGE_MAX),
        2.0f, 5.0f);

    int brg = (int)(ctx->bearing_to_target + 0.5f);
    int rng_km = (int)(ctx->range / 1000.0f + 0.5f);

    switch (ctx->phase) {

        case MERGE_ENTRY: {
            // GCI bestätigt Merge, gibt sofortige Lageinfo
            const char *side = (ctx->bearing_to_target < 180.0f)
                               ? "справа" : "слева";
            snprintf(out->text_ru, sizeof(out->text_ru),
                "%s, контакт %s, %d градусов. Бой.",
                callsign, side, brg);
            snprintf(out->text_en, sizeof(out->text_en),
                "%s, contact %s, %d degrees. FIGHT.",
                callsign,
                (ctx->bearing_to_target < 180.0f) ? "right" : "left",
                brg);
            break;
        }

        case MERGE_OVERSHOOT: {
            // Ziel hinter uns — GCI sieht es sofort
            if (ctx->altitude_delta > 400.0f) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель сзади-ниже, %d. Левый разворот.",
                    callsign, brg);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, bandit behind-low, %d. LEFT turn.",
                    callsign, brg);
            } else if (ctx->altitude_delta < -400.0f) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель сзади-выше, %d. Правый разворот.",
                    callsign, brg);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, bandit behind-high, %d. RIGHT turn.",
                    callsign, brg);
            } else {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель сзади, %d градусов. Разворот!",
                    callsign, brg);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, bandit behind, %d degrees. TURN!",
                    callsign, brg);
            }
            break;
        }

        case MERGE_SEPARATION: {
            if (ctx->pass_count < 3) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель %d градусов, %d км. Повторная атака.",
                    callsign, brg, rng_km);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, bandit %d degrees, %dkm. RE-ATTACK.",
                    callsign, brg, rng_km);
            } else {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, прекрати бой. Домой.",
                    callsign);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, BREAK OFF. RTB.",
                    callsign);
            }
            break;
        }

        case MERGE_REATTACK: {
            // GCI vektiert erneut — kurze, schnelle Befehle
            if (prev->phase != MERGE_REATTACK) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, набери скорость. Цель %d, %d км.",
                    callsign, brg, rng_km);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, gain speed. Target %d, %dkm.",
                    callsign, brg, rng_km);
            } else if (ctx->ticks_in_phase % 3 == 0) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель %d, %d.", callsign, brg, rng_km);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, target %d, %dkm.", callsign, brg, rng_km);
            } else {
                out->silence = true;
            }
            break;
        }

        case MERGE_LOST: {
            if (prev->phase != MERGE_LOST) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, потерял цель на радаре. "
                    "Последний курс %d, высота %d. Визуально!",
                    callsign, brg, (int)ctx->range);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, LOST on radar. "
                    "Last bearing %d. Look for visual!",
                    callsign, brg);
            } else if (ctx->ticks_in_phase == 4) {
                // Nach 20s: Lageabschätzung
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, предположительно %d, %d км. Осторожно.",
                    callsign, brg, rng_km);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, estimated %d, %dkm. Caution.",
                    callsign, brg, rng_km);
            } else {
                out->silence = true;
            }
            break;
        }

        case MERGE_SPLASH: {
            out->delay_sec = 1.5f;
            snprintf(out->text_ru, sizeof(out->text_ru),
                "%s, цель уничтожена. Молодец. Курс домой.",
                callsign);
            snprintf(out->text_en, sizeof(out->text_en),
                "%s, SPLASH. Well done. RTB.",
                callsign);
            break;
        }
    }
}
