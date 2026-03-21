/*
 * gci_lua.c — Lua 5.1 Binding für gci_core
 * ═══════════════════════════════════════════════════════════════
 *
 * Kompilierung (Windows, gegen DCS lua51.dll):
 *   cl /LD /O2 /I include
 *      gci_lua.c src/pursuit_solver.c src/intercept_fsm.c src/merge_controller.c
 *      /link lua51.lib
 *      /OUT:gci_core.dll
 *
 * Kompilierung (MinGW):
 *   gcc -shared -O2 -I include
 *       gci_lua.c src/pursuit_solver.c src/intercept_fsm.c src/merge_controller.c
 *       -llua51 -lm
 *       -o gci_core.dll
 *
 * Installation:
 *   gci_core.dll  →  %USERPROFILE%\Saved Games\DCS\Scripts\gci_core.dll
 *
 * MissionScripting.lua Hook (einmalig, vor sanitizeModule-Aufrufen):
 *   local _path = lfs.writedir() .. "Scripts\\gci_core.dll"
 *   if lfs.attributes(_path) then
 *       package.loadlib(_path, "luaopen_gci")()
 *   end
 *
 * Danach global verfügbar in der Mission-Sandbox:
 *   gci_compute_intercept(f_x, f_z, f_y, f_spd, f_vx, f_vz, f_vy,
 *                         t_x, t_z, t_y, t_spd, t_vx, t_vz, t_vy)
 *   gci_fsm_update(ctx_id, range, aspect, closure, alt_delta, fuel,
 *                  pilot_radar, pilot_visual, threat)
 *   gci_fsm_transmission(ctx_id, callsign,
 *                        hdg, tti, mode, wf, ip_x, ip_z, ip_y)
 *   gci_fsm_reset(ctx_id)
 *   gci_merge_update(ctx_id, rel_bearing, range, altitude_delta, splash)
 */

#define LUA_BUILD_AS_DLL  // vor den Includes!
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <string.h>
#include <math.h>

#include "gci_types.h"
#include "pursuit_solver.h"
#include "intercept_fsm.h"
#include "merge_controller.h"

/* ─────────────────────────────────────────────────────────────
 *  Kontext-Pool
 *  Bis zu GCI_MAX_CONTEXTS gleichzeitige Intercepts (Multi-Flight Phase 5)
 *  ctx_id: 1-basiert (Lua-Konvention)
 * ───────────────────────────────────────────────────────────── */

#define GCI_MAX_CONTEXTS 8

static InterceptContext  g_ctx[GCI_MAX_CONTEXTS];
static MergeContext      g_merge[GCI_MAX_CONTEXTS];
static bool              g_initialized = false;

static void ensure_init(void) {
    if (g_initialized) return;
    for (int i = 0; i < GCI_MAX_CONTEXTS; i++) {
        gci_context_init(&g_ctx[i]);
        gci_merge_context_init(&g_merge[i]);
    }
    g_initialized = true;
}

/* ctx_id validieren und Pointer zurückgeben (NULL bei Fehler) */
static InterceptContext *get_ctx(lua_State *L, int arg) {
    int id = (int)luaL_checkinteger(L, arg);
    if (id < 1 || id > GCI_MAX_CONTEXTS) {
        luaL_error(L, "gci: ctx_id %d ungültig (1..%d)", id, GCI_MAX_CONTEXTS);
        return NULL;
    }
    return &g_ctx[id - 1];
}

static MergeContext *get_merge_ctx(lua_State *L, int arg) {
    int id = (int)luaL_checkinteger(L, arg);
    if (id < 1 || id > GCI_MAX_CONTEXTS) {
        luaL_error(L, "gci: ctx_id %d ungültig (1..%d)", id, GCI_MAX_CONTEXTS);
        return NULL;
    }
    return &g_merge[id - 1];
}


/* ─────────────────────────────────────────────────────────────
 *  Hilfsmakro: Lua-Float sicher lesen
 * ───────────────────────────────────────────────────────────── */
#define GETF(L, n) ((float)luaL_checknumber((L), (n)))


/* ═════════════════════════════════════════════════════════════
 *  1.  gci_compute_intercept
 *
 *  Lua-Signatur:
 *    hdg, tti, mode, wf, range, aspect, ip_x, ip_z, ip_y =
 *        gci_compute_intercept(
 *            f_x, f_z, f_y, f_spd, f_vx, f_vz, f_vy,
 *            t_x, t_z, t_y, t_spd, t_vx, t_vz, t_vy)
 *
 *  Rückgabewerte:
 *    hdg    (number)  Empfohlener Kurs in Grad (0-360)
 *    tti    (number)  Zeit bis Intercept in Sekunden
 *    mode   (string)  "COLLISION" | "LEAD" | "NONE"
 *    wf     (boolean) Waffenfreigabe
 *    range  (number)  Distanz Jäger→Ziel in Metern
 *    aspect (number)  Aspect Angle in Grad
 *    ip_x   (number)  Intercept-Punkt X
 *    ip_z   (number)  Intercept-Punkt Z
 *    ip_y   (number)  Intercept-Punkt Y (Höhe)
 * ═════════════════════════════════════════════════════════════ */

static int l_compute_intercept(lua_State *L) {
    ensure_init();

    AircraftState f, t;
    memset(&f, 0, sizeof(f));
    memset(&t, 0, sizeof(t));

    /* Jäger: args 1-7  (DCS: arg1=dx/Nord, arg2=dy/Höhe, arg3=dz/Ost)
     * GCI-Kern erwartet: x=Ost, z=Nord, y=Höhe
     * Mapping: GCI.x←DCS.dz(arg3), GCI.z←DCS.dx(arg1), GCI.y←DCS.dy(arg2) */
    f.pos.x  = GETF(L, 3);   /* DCS dz (Ost)  → GCI x */
    f.pos.z  = GETF(L, 1);   /* DCS dx (Nord) → GCI z */
    f.pos.y  = GETF(L, 2);   /* DCS dy (Höhe) → GCI y */
    f.speed  = GETF(L, 4);
    f.vel.x  = GETF(L, 7);   /* DCS vz (Ost)  → GCI vx */
    f.vel.z  = GETF(L, 5);   /* DCS vx (Nord) → GCI vz */
    f.vel.y  = GETF(L, 6);   /* DCS vy        → GCI vy */

    /* Ziel: args 8-14 (gleiches Mapping) */
    t.pos.x  = GETF(L, 10);  /* DCS dz → GCI x */
    t.pos.z  = GETF(L, 8);   /* DCS dx → GCI z */
    t.pos.y  = GETF(L, 9);   /* DCS dy → GCI y */
    t.speed  = GETF(L, 11);
    t.vel.x  = GETF(L, 14);  /* DCS vz → GCI vx */
    t.vel.z  = GETF(L, 12);  /* DCS vx → GCI vz */
    t.vel.y  = GETF(L, 13);  /* DCS vy → GCI vy */

    /* Mindestgeschwindigkeit — unter 10 m/s keine sinnvolle Geometrie */
    if (f.speed < 10.0f) {
        lua_pushnumber(L, 0.0);
        lua_pushnumber(L, 0.0);
        lua_pushstring(L, "NONE");
        lua_pushboolean(L, 0);
        lua_pushnumber(L, 0.0);
        lua_pushnumber(L, 0.0);
        lua_pushnumber(L, 0.0);
        lua_pushnumber(L, 0.0);
        lua_pushnumber(L, 0.0);
        return 9;
    }

    InterceptSolution sol = gci_compute_intercept(&f, &t);

    const char *mode_str = "NONE";
    if (sol.solution_found) {
        switch (sol.mode) {
            case PURSUIT_COLLISION: mode_str = "COLLISION"; break;
            case PURSUIT_LEAD:      mode_str = "LEAD";      break;
            case PURSUIT_PURE:      mode_str = "PURE";      break;
            default:                mode_str = "NONE";      break;
        }
    }

    lua_pushnumber(L,  sol.heading_deg);
    lua_pushnumber(L,  sol.time_to_intercept);
    lua_pushstring(L,  mode_str);
    lua_pushboolean(L, sol.weapons_free ? 1 : 0);
    lua_pushnumber(L,  sol.range);
    lua_pushnumber(L,  sol.aspect_angle);
    /* Intercept-Punkt zurück nach DCS-Koordinaten:
     * GCI x(Ost)→DCS dz,  GCI z(Nord)→DCS dx,  GCI y(Höhe)→DCS dy */
    lua_pushnumber(L,  sol.intercept_point.z);   /* DCS dx (Nord) */
    lua_pushnumber(L,  sol.intercept_point.x);   /* DCS dy (Höhe) */
    lua_pushnumber(L,  sol.intercept_point.y);   /* DCS dz (Ost)  */
    return 9;
}


/* ═════════════════════════════════════════════════════════════
 *  2.  gci_fsm_update
 *
 *  Lua-Signatur:
 *    state, ticks =
 *        gci_fsm_update(ctx_id,
 *            range, aspect, closure, alt_delta, fuel,
 *            pilot_radar, pilot_visual, threat)
 *
 *  Rückgabewerte:
 *    state  (string)  Neuer FSM-State als String
 *    ticks  (number)  Ticks im aktuellen State
 * ═════════════════════════════════════════════════════════════ */

static const char *state_to_str(InterceptState s) {
    switch (s) {
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

static int l_fsm_update(lua_State *L) {
    ensure_init();

    InterceptContext *ctx = get_ctx(L, 1);
    if (!ctx) return 0;

    float range     = GETF(L, 2);
    float aspect    = GETF(L, 3);
    float closure   = GETF(L, 4);
    float alt_delta = GETF(L, 5);
    float fuel      = GETF(L, 6);
    bool  p_radar   = lua_toboolean(L, 7) != 0;
    bool  p_visual  = lua_toboolean(L, 8) != 0;
    bool  threat    = lua_toboolean(L, 9) != 0;

    /* Pilot-Flags in Kontext schreiben */
    ctx->pilot_has_radar  = p_radar;
    ctx->pilot_has_visual = p_visual;
    ctx->threat_detected  = threat;

    /* Kontext-Werte aktualisieren */
    gci_context_update(ctx, range, aspect, closure, alt_delta, fuel);

    /* FSM-Übergang berechnen */
    InterceptState new_state = gci_fsm_transition(ctx);

    /* State-Tracking */
    if (new_state != ctx->state) {
        ctx->prev_state     = ctx->state;
        ctx->state          = new_state;
        ctx->ticks_in_state = 0;
    } else {
        ctx->ticks_in_state++;
    }

    lua_pushstring(L, state_to_str(ctx->state));
    lua_pushinteger(L, ctx->ticks_in_state);
    return 2;
}


// ─────────────────────────────────────────────────────────────
//  l_fsm_transmission — Lua Binding (Token-String Version)
//
//  Lua-Aufruf:
//    local silence, token_str, weapons_free, delay =
//        _gci.gci_fsm_transmission(
//            id, callsign,
//            hdg, tti, mode_str, wf,
//            ip_x, ip_z, ip_y,
//            target_alt)   -- NEU: Zielhöhe ohne Offset
//
//  Rückgabe (4 Werte):
//    silence      boolean
//    token_str    string   z.B. "VECTOR|hdg=165|alt=4500|..."
//    weapons_free boolean
//    delay        number   Sekunden
// ─────────────────────────────────────────────────────────────

static int l_fsm_transmission(lua_State *L)
{
    ensure_init();
    InterceptContext *ctx = get_ctx(L, 1);
    if (!ctx) return 0;

    const char *callsign = luaL_checkstring(L, 2);

    /* Intercept-Lösung aus Lua-Argumenten rekonstruieren */
    InterceptSolution sol;
    memset(&sol, 0, sizeof(sol));
    sol.heading_deg       = GETF(L, 3);
    sol.time_to_intercept = GETF(L, 4);
    /* arg 5: mode_str — nur für Vollständigkeit, nicht genutzt */
    sol.weapons_free      = lua_toboolean(L, 6) != 0;
    sol.intercept_point.x = GETF(L, 7);
    sol.intercept_point.z = GETF(L, 8);
    sol.intercept_point.y = GETF(L, 9);
    sol.target_alt        = GETF(L, 10);   /* Zielhöhe ohne Look-Down Offset */
    sol.solution_found    = (sol.heading_deg > 0.0f ||
                             sol.time_to_intercept > 0.0f);

    /* Transmission bauen */
    GCITransmission tx;
    InterceptContext prev = *ctx;   /* Snapshot für Delta-Logik */
    prev.state = ctx->prev_state;   /* Delta-Logik gegen vorherigen State */
    gci_build_transmission(ctx, &prev, callsign, &sol, &tx);

    /* 4 Rückgabewerte */
    lua_pushboolean(L, tx.silence      ? 1 : 0);
    lua_pushstring (L, tx.token_str);
    lua_pushboolean(L, tx.weapons_free ? 1 : 0);
    lua_pushnumber (L, tx.delay_sec);
    return 4;
}


/* ═════════════════════════════════════════════════════════════
 *  4.  gci_fsm_reset
 *
 *  Lua-Signatur:
 *    gci_fsm_reset(ctx_id)
 *
 *  Setzt einen Intercept-Kontext zurück (z.B. nach Splash oder RTB)
 * ═════════════════════════════════════════════════════════════ */

static int l_fsm_reset(lua_State *L) {
    ensure_init();
    InterceptContext *ctx = get_ctx(L, 1);
    if (!ctx) return 0;

    int id = (int)luaL_checkinteger(L, 1);
    gci_context_init(ctx);
    gci_merge_context_init(&g_merge[id - 1]);
    return 0;
}


/* ═════════════════════════════════════════════════════════════
 *  5.  gci_merge_update
 *
 *  Lua-Signatur:
 *    phase, text_ru, text_en, silence =
 *        gci_merge_update(ctx_id, callsign,
 *            rel_bearing, range, altitude_delta, splash)
 *
 *  Rückgabewerte:
 *    phase    (string)   Merge-Phase
 *    text_ru  (string)
 *    text_en  (string)
 *    silence  (boolean)
 * ═════════════════════════════════════════════════════════════ */

static int l_merge_update(lua_State *L) {
    ensure_init();

    MergeContext *mctx = get_merge_ctx(L, 1);
    if (!mctx) return 0;

    const char *callsign  = luaL_checkstring(L, 2);
    float rel_bearing     = GETF(L, 3);
    float range           = GETF(L, 4);
    float altitude_delta  = GETF(L, 5);
    bool  splash          = lua_toboolean(L, 6) != 0;

    /* Kontext aktualisieren */
    MergeContext prev = *mctx;
    mctx->bearing_to_target = rel_bearing;
    mctx->range             = range;
    mctx->altitude_delta    = altitude_delta;

    if (splash) {
        mctx->phase = MERGE_SPLASH;
    } else {
        MergePhase new_phase = gci_merge_transition(mctx, &prev);
        if (new_phase != mctx->phase) {
            mctx->phase         = new_phase;
            mctx->ticks_in_phase = 0;
        } else {
            mctx->ticks_in_phase++;
        }
    }

    /* Transmission bauen */
    GCITransmission tx;
    gci_build_merge_transmission(mctx, &prev, callsign, &tx);

    /* Phase als String */
    const char *phase_str = "ENTRY";
    switch (mctx->phase) {
        case MERGE_ENTRY:      phase_str = "ENTRY";      break;
        case MERGE_OVERSHOOT:  phase_str = "OVERSHOOT";  break;
        case MERGE_SEPARATION: phase_str = "SEPARATION"; break;
        case MERGE_REATTACK:   phase_str = "REATTACK";   break;
        case MERGE_LOST:       phase_str = "LOST";       break;
        case MERGE_SPLASH:     phase_str = "SPLASH";     break;
        default:               phase_str = "UNKNOWN";    break;
    }

    lua_pushstring(L,  phase_str);
    lua_pushstring(L,  tx.token_str);
    lua_pushboolean(L, tx.silence ? 1 : 0);
    lua_pushnumber(L,  tx.delay_sec);
    return 4;
}


/* ═════════════════════════════════════════════════════════════
 *  6.  gci_compute_split  (2v2 Taktik-Split)
 *
 *  Berechnet Split- und Merge-Einflugpunkte für zwei Fighter.
 *  Einmalig bei COMMIT aufgerufen; merge-WPs werden jeden Tick
 *  vom Lua-Layer nachgeführt.
 *
 *  Lua-Signatur:
 *    wp1_x,wp1_z,wp1_y, wp2_x,wp2_z,wp2_y,
 *    mp1_x,mp1_z,mp1_y, mp2_x,mp2_z,mp2_y =
 *        gci_compute_split(
 *            f1_x, f1_y, f1_z,      -- DCS-Koordinaten Fighter 1
 *            f2_x, f2_y, f2_z,      -- DCS-Koordinaten Fighter 2
 *            tgt_x, tgt_y, tgt_z,   -- DCS Ziel-Mittelpunkt
 *            tactic,                -- 0=PINCER,1=HIGH_LOW,2=STAGGER,3=TRAIL
 *            variation)             -- 0.0–1.0 Zufallsanteil
 *
 *  Alle Koordinaten in DCS-Format (x=Nord, y=Höhe, z=Ost).
 *  Rückgabe: 12 Werte (4 WPs × 3), ebenfalls DCS-Format.
 *  Namenskonvention: wp_x = DCS-x (Nord), wp_z = DCS-z (Ost).
 * ═════════════════════════════════════════════════════════════ */

static int l_compute_split(lua_State *L) {
    ensure_init();

    AircraftState f1, f2;
    memset(&f1, 0, sizeof(f1));
    memset(&f2, 0, sizeof(f2));

    /* Mapping: DCS x(Nord)→GCI z, DCS y(Höhe)→GCI y, DCS z(Ost)→GCI x */

    /* Fighter 1: args 1-3 */
    f1.pos.z = GETF(L, 1);   /* DCS x (Nord) → GCI z */
    f1.pos.y = GETF(L, 2);   /* DCS y (Höhe) → GCI y */
    f1.pos.x = GETF(L, 3);   /* DCS z (Ost)  → GCI x */

    /* Fighter 2: args 4-6 */
    f2.pos.z = GETF(L, 4);
    f2.pos.y = GETF(L, 5);
    f2.pos.x = GETF(L, 6);

    /* Ziel-Mittelpunkt: args 7-9 */
    float tgt_z = GETF(L, 7);   /* DCS x (Nord) → GCI z */
    float tgt_y = GETF(L, 8);   /* Höhe          → GCI y */
    float tgt_x = GETF(L, 9);   /* DCS z (Ost)  → GCI x */

    int   tactic_int = (int)luaL_checkinteger(L, 10);
    float variation  = GETF(L, 11);

    if (tactic_int < 0 || tactic_int > 3) tactic_int = 0;
    if (variation  < 0.0f) variation = 0.0f;
    if (variation  > 1.0f) variation = 1.0f;

    TacticSplitPlan plan = gci_compute_split(
        &f1, &f2,
        tgt_x, tgt_z, tgt_y,
        (TacticType)tactic_int,
        variation);

    /* Rückgabe: GCI→DCS  (GCI z/Nord→DCS x,  GCI x/Ost→DCS z,  y=y) */
    /* wp_f1 */
    lua_pushnumber(L, plan.wp_f1.z);    /* DCS x (Nord) */
    lua_pushnumber(L, plan.wp_f1.x);    /* DCS z (Ost)  */
    lua_pushnumber(L, plan.wp_f1.y);    /* Höhe         */
    /* wp_f2 */
    lua_pushnumber(L, plan.wp_f2.z);
    lua_pushnumber(L, plan.wp_f2.x);
    lua_pushnumber(L, plan.wp_f2.y);
    /* merge_f1 */
    lua_pushnumber(L, plan.merge_f1.z);
    lua_pushnumber(L, plan.merge_f1.x);
    lua_pushnumber(L, plan.merge_f1.y);
    /* merge_f2 */
    lua_pushnumber(L, plan.merge_f2.z);
    lua_pushnumber(L, plan.merge_f2.x);
    lua_pushnumber(L, plan.merge_f2.y);
    return 12;
}


/* ═════════════════════════════════════════════════════════════
 *  7.  gci_version  (Debugging)
 *
 *  Lua-Signatur:
 *    version_string = gci_version()
 * ═════════════════════════════════════════════════════════════ */

static int l_version(lua_State *L) {
    lua_pushstring(L, "GCI_CORE 0.2.0-dll (Phase 2)");
    return 1;
}


/* ─────────────────────────────────────────────────────────────
 *  Funktionstabelle
 * ───────────────────────────────────────────────────────────── */

static const luaL_Reg gci_funcs[] = {
    { "gci_compute_intercept", l_compute_intercept },
    { "gci_compute_split",     l_compute_split     },
    { "gci_fsm_update",        l_fsm_update        },
    { "gci_fsm_transmission",  l_fsm_transmission  },
    { "gci_fsm_reset",         l_fsm_reset         },
    { "gci_merge_update",      l_merge_update      },
    { "gci_version",           l_version           },
    { NULL, NULL }
};


/* ─────────────────────────────────────────────────────────────
 *  luaopen_RedGCI — Entry Point
 *  DCS ruft require("RedGCI") auf → luaopen_RedGCI wird aufgerufen
 *  Lua-Konvention: require("X") sucht luaopen_X in X.dll
 * ───────────────────────────────────────────────────────────── */

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
int luaopen_RedGCI(lua_State *L) {
    ensure_init();

    /* Als Tabelle "gci" registrieren — analog zu luaL_register in HoundTTS */
    luaL_register(L, "RedGCI", gci_funcs);

    /* Zusätzlich alle Funktionen global verfügbar machen —
     * gci_bridge.lua ruft gci_compute_intercept() direkt auf, nicht gci.gci_compute_intercept() */
    const luaL_Reg *f = gci_funcs;
    while (f->name) {
        lua_getfield(L, -1, f->name);   /* hole Funktion aus der Tabelle */
        lua_setglobal(L, f->name);      /* setze als global */
        f++;
    }

    /* Tabelle auf Stack lassen — Lua erwartet 1 Rückgabewert */
    return 1;
}

#ifdef __cplusplus
}
#endif
