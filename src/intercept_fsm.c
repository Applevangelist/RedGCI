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

void gci_build_transmission(
    const InterceptContext  *ctx,
    const InterceptContext  *prev,
    const char              *callsign,
    const InterceptSolution *sol,
    GCITransmission         *out)
{
    memset(out, 0, sizeof(*out));
    out->silence   = false;
    out->delay_sec = GCI_CLAMP(
        gci_randf(GCI_DELAY_MIN, GCI_DELAY_MAX), 3.0f, 8.0f);

    int hdg_i = (int)(sol->heading_deg + 0.5f);
    int alt_i = (int)(sol->intercept_point.y);
    int rng_km = (int)(ctx->range / 1000.0f + 0.5f);
    int tti_m  = (int)(sol->time_to_intercept / 60.0f);
    int tti_s  = (int)(sol->time_to_intercept) % 60;

    switch (ctx->state) {

        // ── VECTOR ───────────────────────────────────────────
        case STATE_VECTOR: {
            snprintf(out->text_ru, sizeof(out->text_ru),
                "%s, курс %03d, высота %d, скорость девятьсот.",
                callsign, hdg_i, alt_i);
            snprintf(out->text_en, sizeof(out->text_en),
                "%s, VECTOR %03d, altitude %dm, 900 kph.",
                callsign, hdg_i, alt_i);

            // Nur bei bedeutender Kursänderung oder erstem Tick
            if (prev->state != STATE_VECTOR)
                break;

            float hdg_delta = fabsf(sol->heading_deg -
                gci_bearing(ctx->range, 0.0f));  // vereinfacht
            if (hdg_delta < 5.0f && ctx->ticks_in_state > 3) {
                out->silence = true;  // Kurs stabil, nicht nerven
            }
            break;
        }

        // ── COMMIT ───────────────────────────────────────────
        case STATE_COMMIT: {
            bool first = (prev->state != STATE_COMMIT);

            if (first) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель впереди, дальность %d, высота %d. "
                    "Включи локатор. Ищи.",
                    callsign, rng_km, alt_i);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, BOGEY ahead, %dkm, altitude %dm. "
                    "Search radar. Look.",
                    callsign, rng_km, alt_i);
            } else if (ctx->ticks_in_state == 6) {
                // 30 Sekunden vergangen (6 Takte × 5s), immer noch kein Lock
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, поправка: азимут %d, дальность %d. "
                    "Почему нет захвата?",
                    callsign,
                    (int)ctx->aspect_angle,
                    rng_km);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, CORRECTION: bearing %d, %dkm. "
                    "Why no lock?",
                    callsign,
                    (int)ctx->aspect_angle,
                    rng_km);
            } else if (ctx->ticks_in_state > 8) {
                // >40s — Mikrokorrektur
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, довернись %s десять градусов.",
                    callsign,
                    (ctx->aspect_angle > 5.0f) ? "вправо" : "влево");
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, turn %s ten degrees.",
                    callsign,
                    (ctx->aspect_angle > 5.0f) ? "right" : "left");
            } else {
                out->silence = true;
            }
            break;
        }

        // ── RADAR CONTACT ─────────────────────────────────────
        case STATE_RADAR_CONTACT: {
            if (prev->state != STATE_RADAR_CONTACT) {
                // Erster Tick nach Lock-Meldung
                if (sol->weapons_free) {
                    snprintf(out->text_ru, sizeof(out->text_ru),
                        "%s, захват подтверждён. Дальность %d. "
                        "Цель разрешена. Атакуй.",
                        callsign, rng_km);
                    snprintf(out->text_en, sizeof(out->text_en),
                        "%s, lock confirmed. %dkm. "
                        "WEAPONS FREE. Attack.",
                        callsign, rng_km);
                    out->weapons_free = true;
                } else {
                    snprintf(out->text_ru, sizeof(out->text_ru),
                        "%s, захват подтверждён. Дальность %d. "
                        "Жди разрешения.",
                        callsign, rng_km);
                    snprintf(out->text_en, sizeof(out->text_en),
                        "%s, lock confirmed. %dkm. "
                        "Await clearance.",
                        callsign, rng_km);
                }
            } else if (!sol->weapons_free && ctx->range < GCI_WF_RANGE_MAX
                       && ctx->aspect_angle > GCI_ASPECT_REAR_ATTACK
                       && prev->state == STATE_RADAR_CONTACT) {
                // Waffenfreigabe gerade erreicht
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель разрешена.",
                    callsign);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, WEAPONS FREE.",
                    callsign);
                out->weapons_free = true;
            } else {
                // GCI schweigt — Pilot arbeitet
                out->silence = true;
            }
            break;
        }

        // ── VISUAL ───────────────────────────────────────────
        case STATE_VISUAL: {
            if (prev->state != STATE_VISUAL) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, визуальный. Цель разрешена.",
                    callsign);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, visual confirmed. WEAPONS FREE.",
                    callsign);
                out->weapons_free = true;
            } else {
                out->silence = true;
            }
            break;
        }

        // ── NOTCH ─────────────────────────────────────────────
        case STATE_NOTCH: {
            if (prev->state != STATE_NOTCH) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель маневрирует. Жди команды.",
                    callsign);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, target maneuvering. Standby.",
                    callsign);
            } else if (ctx->ticks_in_state % 8 == 0) {
                // Alle 40s ein Lageupdate
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, цель %s, дальность %d. Держи.",
                    callsign,
                    bearing_clock(ctx->aspect_angle),
                    rng_km);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, target %s, %dkm. Hold.",
                    callsign,
                    bearing_clock(ctx->aspect_angle),
                    rng_km);
            } else {
                out->silence = true;
            }
            break;
        }

        // ── ABORT ─────────────────────────────────────────────
        case STATE_ABORT: {
            out->delay_sec = 1.5f;  // Sofort!
            if (ctx->fuel_fraction < GCI_FUEL_BINGO) {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, топливо критическое. Прекрати атаку. "
                    "Немедленно домой. Курс %03d.",
                    callsign, hdg_i);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, BINGO FUEL. Break off. "
                    "RTB immediately. Course %03d.",
                    callsign, hdg_i);
            } else {
                snprintf(out->text_ru, sizeof(out->text_ru),
                    "%s, угроза. Прекрати атаку. "
                    "Курс %03d, снижайся.",
                    callsign, hdg_i);
                snprintf(out->text_en, sizeof(out->text_en),
                    "%s, THREAT WARNING. Break off. "
                    "Course %03d, descend.",
                    callsign, hdg_i);
            }
            break;
        }

        // ── MERGE — handled by merge_controller ──────────────
        case STATE_MERGE:
        case STATE_RTB:
        default:
            out->silence = true;
            break;
    }

    // Geschätzte Zeit nur in VECTOR ausgeben (wenn >60s)
    if (ctx->state == STATE_VECTOR && tti_m > 0 &&
        !out->silence && prev->state != STATE_VECTOR) {
        char tti_buf[64];
        snprintf(tti_buf, sizeof(tti_buf),
            " До цели %d мин.", tti_m);
        strncat(out->text_ru,
                tti_buf, sizeof(out->text_ru) - strlen(out->text_ru) - 1);
        (void)tti_s;
    }
}
