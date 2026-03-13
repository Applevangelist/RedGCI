#include "message_handler.h"
#include "pursuit_solver.h"
#include "intercept_fsm.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

// ─────────────────────────────────────────────────────────────
//  Sitzungs-State (ein einziger Intercept für den POC)
// ─────────────────────────────────────────────────────────────

static InterceptContext  s_ctx;
static InterceptContext  s_prev_ctx;
static MergeContext      s_merge;
static MergeContext      s_prev_merge;
static bool              s_initialized = false;

static float s_last_hdg = 0.0f;

static const char *s_callsign = "Сокол-1";

void gci_session_reset(void) {
    gci_context_init(&s_ctx);
    gci_context_init(&s_prev_ctx);
    gci_merge_context_init(&s_merge);
    gci_merge_context_init(&s_prev_merge);
    s_initialized = true;
}

// ─────────────────────────────────────────────────────────────
//  State-Namen für Debug-Output
// ─────────────────────────────────────────────────────────────

static const char *state_name(InterceptState s) {
    switch(s) {
        case STATE_VECTOR:        return "VECTOR";
        case STATE_COMMIT:        return "COMMIT";
        case STATE_RADAR_CONTACT: return "RADAR_CONTACT";
        case STATE_VISUAL:        return "VISUAL";
        case STATE_MERGE:         return "MERGE";
        case STATE_NOTCH:         return "NOTCH";
        case STATE_ABORT:         return "ABORT";
        case STATE_RTB:           return "RTB";
        default:                  return "UNKNOWN";
    }
}

static const char *mode_name(PursuitMode m) {
    switch(m) {
        case PURSUIT_COLLISION: return "COLLISION";
        case PURSUIT_LEAD:      return "LEAD";
        case PURSUIT_PURE:      return "PURE";
        default:                return "NONE";
    }
}

// ─────────────────────────────────────────────────────────────
//  Haupt-Dispatcher
// ─────────────────────────────────────────────────────────────

int gci_process_message(const char *msg, char *out, int out_len) {
    if (!s_initialized)
        gci_session_reset();

    // ── PING ─────────────────────────────────────────────────
    if (strcmp(msg, "PING") == 0) {
        snprintf(out, out_len, "PONG");
        return 0;
    }

    // ── RESET ────────────────────────────────────────────────
    if (strcmp(msg, "RESET") == 0) {
        gci_session_reset();
        snprintf(out, out_len, "OK:RESET");
        return 0;
    }

    // ── INTERCEPT|fx|fz|fy|fspd|tx|tz|ty|tspd|tvx|tvz|tvy ──
    if (strncmp(msg, "INTERCEPT|", 10) == 0) {
        AircraftState fighter = {0}, target = {0};
        float tvx = 0.0f, tvz = 0.0f, tvy = 0.0f;

        int parsed = sscanf(msg + 10,
            "%f|%f|%f|%f|%f|%f|%f|%f|%f|%f|%f",
            &fighter.pos.x, &fighter.pos.z, &fighter.pos.y, &fighter.speed,
            &target.pos.x,  &target.pos.z,  &target.pos.y,  &target.speed,
            &tvx, &tvz, &tvy);

        if (parsed < 8) {
            snprintf(out, out_len, "ERR:PARSE_FAILED(%d)", parsed);
            return -1;
        }

        target.vel.x  = tvx;
        target.vel.z  = tvz;
        target.vel.y  = tvy;
        fighter.vel.x = 0.0f;
        fighter.vel.z = 0.0f;

        // Geometrie berechnen
        float range   = gci_vec2_len(
            target.pos.x - fighter.pos.x,
            target.pos.z - fighter.pos.z);
        float aspect  = gci_aspect_angle(&target, &fighter);
        float closure = gci_closure_rate(&fighter, &target);
        float alt_d   = fighter.pos.y - target.pos.y;

        // FSM aktualisieren
        gci_context_update(&s_ctx, range, aspect, closure,
                           alt_d, s_ctx.fuel_fraction);

        s_prev_ctx = s_ctx;
        InterceptState new_state = gci_fsm_transition(&s_ctx);

        if (new_state != s_ctx.state) {
            s_ctx.prev_state     = s_ctx.state;
            s_ctx.state          = new_state;
            s_ctx.ticks_in_state = 0;
        } else {
            s_ctx.ticks_in_state++;
        }

        // Intercept-Lösung berechnen
        InterceptSolution sol = gci_compute_intercept(&fighter, &target);
        s_last_hdg = sol.heading_deg;

        // Transmission generieren
        GCITransmission tx;
        if (s_ctx.state == STATE_MERGE) {
            s_prev_merge = s_merge;
            s_merge.range             = range;
            s_merge.bearing_to_target = aspect;
            s_merge.altitude_delta    = alt_d;
            s_merge.closure_rate      = closure;

            MergePhase new_phase = gci_merge_transition(&s_merge, &s_prev_merge);
            if (new_phase != s_merge.phase) {
                s_merge.phase          = new_phase;
                s_merge.ticks_in_phase = 0;
            } else {
                s_merge.ticks_in_phase++;
            }
            gci_build_merge_transmission(&s_merge, &s_prev_merge,
                                          s_callsign, &tx);
        } else {
            gci_build_transmission(&s_ctx, &s_prev_ctx,
                                    s_callsign, &sol, &tx);
        }

        // Antwort formatieren — token_str statt text_ru/text_en
        if (tx.silence) {
            snprintf(out, out_len, "SILENCE");
        } else {
            snprintf(out, out_len,
                "HDG:%03d|TTI:%.0f|MODE:%s|WF:%d|"
                "STATE:%s|RANGE:%.0f|ASPECT:%.1f|DELAY:%.1f|"
                "TOKEN:%s",
                (int)(sol.heading_deg + 0.5f),
                sol.time_to_intercept,
                mode_name(sol.mode),
                (int)tx.weapons_free,
                state_name(s_ctx.state),
                range, aspect, tx.delay_sec,
                tx.token_str);
        }
        return 0;
    }

    // ── PILOT_RADAR|flight_id|1 ──────────────────────────────
    if (strncmp(msg, "PILOT_RADAR|", 12) == 0) {
        int val = 0;
        sscanf(msg + 12, "%*[^|]|%d", &val);
        s_ctx.pilot_has_radar = (val != 0);
        snprintf(out, out_len, "OK:RADAR=%d", val);
        return 0;
    }

    // ── PILOT_VISUAL|flight_id|1 ─────────────────────────────
    if (strncmp(msg, "PILOT_VISUAL|", 13) == 0) {
        int val = 0;
        sscanf(msg + 13, "%*[^|]|%d", &val);
        s_ctx.pilot_has_visual = (val != 0);
        snprintf(out, out_len, "OK:VISUAL=%d", val);
        return 0;
    }

    // ── PILOT_THREAT|flight_id|1 ─────────────────────────────
    if (strncmp(msg, "PILOT_THREAT|", 13) == 0) {
        int val = 0;
        sscanf(msg + 13, "%*[^|]|%d", &val);
        s_ctx.threat_detected = (val != 0);
        snprintf(out, out_len, "OK:THREAT=%d", val);
        return 0;
    }

    // ── FUEL|flight_id|0.45 ──────────────────────────────────
    if (strncmp(msg, "FUEL|", 5) == 0) {
        float f = 1.0f;
        sscanf(msg + 5, "%*[^|]|%f", &f);
        s_ctx.fuel_fraction = GCI_CLAMP(f, 0.0f, 1.0f);
        snprintf(out, out_len, "OK:FUEL=%.2f", s_ctx.fuel_fraction);
        return 0;
    }

    // ── MERGE_SPLASH ─────────────────────────────────────────
    if (strcmp(msg, "MERGE_SPLASH") == 0) {
        s_merge.phase = MERGE_SPLASH;
        GCITransmission tx;
        gci_build_merge_transmission(&s_merge, &s_prev_merge,
                                      s_callsign, &tx);
        snprintf(out, out_len, "TOKEN:%s", tx.token_str);
        return 0;
    }

    snprintf(out, out_len, "ERR:UNKNOWN_MSG");
    return -1;
}
