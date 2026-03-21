#include "pursuit_solver.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>

// ─────────────────────────────────────────────────────────────
//  Aspect Angle: Winkel zwischen Ziel-Heading und Linie Ziel→Beobachter
//  0° = Nose-on (Ziel fliegt direkt auf uns zu)
//  90° = Beam (Ziel fliegt quer)
//  180° = Tail (Ziel fliegt direkt weg)
// ─────────────────────────────────────────────────────────────

float gci_aspect_angle(const AircraftState *target,
                        const AircraftState *observer) {
    float dx = observer->pos.x - target->pos.x;
    float dz = observer->pos.z - target->pos.z;
    float range = gci_vec2_len(dx, dz);
    if (range < 1.0f) return 0.0f;

    // Normierter Vektor: Ziel → Beobachter
    float nx = dx / range;
    float nz = dz / range;

    // Normierter Ziel-Heading-Vektor
    float spd = target->speed + 1e-6f;
    float tvx = target->vel.x / spd;
    float tvz = target->vel.z / spd;

    float dot = GCI_CLAMP(tvx*nx + tvz*nz, -1.0f, 1.0f);
    return acosf(dot) * GCI_RAD2DEG;
}


// ─────────────────────────────────────────────────────────────
//  Closure Rate: positive Werte = annähernd (gut)
// ─────────────────────────────────────────────────────────────

float gci_closure_rate(const AircraftState *f, const AircraftState *t) {
    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;
    float range = gci_vec2_len(dx, dz);
    if (range < 1.0f) return 0.0f;

    // Einheitsvektor Jäger→Ziel
    float nx = dx / range;
    float nz = dz / range;

    // Relative Geschwindigkeit projiziert auf die Verbindungslinie
    float dvx = t->vel.x - f->vel.x;
    float dvz = t->vel.z - f->vel.z;

    // Negativ weil wir "Annäherung" als positiv definieren
    return -(dvx*nx + dvz*nz);
}


// ─────────────────────────────────────────────────────────────
//  COLLISION COURSE SOLVER
//  Löst quadratische Gleichung für Treffpunkt.
//
//  Herleitung:
//    Treffbedingung: |F + Vf*t - (T + Vt*t)|² = 0
//    Setze d = T - F  und  w = Vt
//    Dann: |d + w*t - Vf*t|² = (|Vf|*t)²
//    Da |Vf| fest und wir Richtung suchen:
//    |d + w*t|² = |Vf|²*t²
//    → quadratisch in t
//
//  Koordinatensystem: GCI intern (x=Ost, z=Nord, y=Höhe)
// ─────────────────────────────────────────────────────────────

bool gci_solve_collision(const AircraftState *f, const AircraftState *t,
                          float *hdg, float *tti, Vec3 *ip) {
    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;

    float vtx = t->vel.x;
    float vtz = t->vel.z;
    float vf  = f->speed;

    // Koeffizienten der quadratischen Gleichung: a*t² + b*t + c = 0
    float a = vtx*vtx + vtz*vtz - vf*vf;
    float b = 2.0f * (dx*vtx + dz*vtz);
    float c = dx*dx + dz*dz;

    float sol_t = -1.0f;

    if (fabsf(a) < 1.0f) {
        // Gleiche Geschwindigkeit: lineare Gleichung
        if (fabsf(b) > 0.01f)
            sol_t = -c / b;
        else
            return false;
    } else {
        float disc = b*b - 4.0f*a*c;
        if (disc < 0.0f) return false;   // Jäger definitiv zu langsam

        float sq = sqrtf(disc);
        float t1 = (-b - sq) / (2.0f * a);
        float t2 = (-b + sq) / (2.0f * a);

        // Kleinste positive Zeit
        if      (t1 > 0.0f && t2 > 0.0f) sol_t = (t1 < t2) ? t1 : t2;
        else if (t1 > 0.0f)               sol_t = t1;
        else if (t2 > 0.0f)               sol_t = t2;
        else return false;
    }

    if (sol_t < 0.0f || sol_t > GCI_MAX_TTI) return false;

    // Treffpunkt — Look-Down Offset direkt hier addieren
    ip->x = t->pos.x + vtx * sol_t;
    ip->z = t->pos.z + vtz * sol_t;
    ip->y = t->pos.y + GCI_ALT_OFFSET_LOOKDOWN;
    /* vel.y weglassen — Ziel manövriert vertikal, nächster Tick korrigiert */
    /* Mindesthöhe 300m — verhindert negative WP-Höhe wenn Ziel sinkt */
    if (ip->y < 300.0f) ip->y = 300.0f;

    // Kurs zum Treffpunkt
    *hdg = gci_bearing(ip->x - f->pos.x, ip->z - f->pos.z);
    *tti = sol_t;
    return true;
}


// ─────────────────────────────────────────────────────────────
//  LEAD PURSUIT
//  Sinus-Regel: sin(lead) / |Vt| = sin(aspect_from_target) / |Vf|
//  Fallback auf Pure Pursuit wenn Lead-Winkel > 45°
// ─────────────────────────────────────────────────────────────

void gci_solve_lead(const AircraftState *f, const AircraftState *t,
                     float *hdg, float *tti) {
    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;
    float range = gci_vec2_len(dx, dz);
    if (range < 1.0f) { *hdg = 0.0f; *tti = 0.0f; return; }

    float base_bearing = gci_bearing(dx, dz);

    float aspect_rad  = gci_aspect_angle(t, f) * GCI_DEG2RAD;
    float speed_ratio = t->speed / (f->speed + 1e-6f);
    float sin_lead    = GCI_CLAMP(speed_ratio * sinf(aspect_rad), -1.0f, 1.0f);
    float lead_deg    = asinf(sin_lead) * GCI_RAD2DEG;

    // Lead-Winkel nur anwenden wenn sinnvoll (<45°)
    // Bei großem Lead würde der GCI den Piloten in die falsche Richtung schicken
    if (fabsf(lead_deg) < 45.0f) {
        *hdg = fmodf(base_bearing + lead_deg + 360.0f, 360.0f);
    } else {
        *hdg = base_bearing;   // Fallback: direkt auf Ziel
    }

  /* TTI: Abstand / (Jägergeschwindigkeit - Zielgeschwindigkeit-Projektion) */
  float closing = gci_closure_rate(f, t);
  if (closing < 50.0f) closing = 50.0f;  /* Minimum 50 m/s — verhindert TTI-Explosion */
  *tti = range / closing;
  /* Hard cap */
  if (*tti > GCI_MAX_TTI) *tti = GCI_MAX_TTI;
}


// ─────────────────────────────────────────────────────────────
//  PURE PURSUIT — immer direkt auf aktuellen Zielort
// ─────────────────────────────────────────────────────────────

void gci_solve_pure(const AircraftState *f, const AircraftState *t,
                     float *hdg, float *tti) {
    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;
    float range = gci_vec2_len(dx, dz);

    *hdg = gci_bearing(dx, dz);
    *tti = range / (f->speed > 1.0f ? f->speed : 1.0f);
}


// ─────────────────────────────────────────────────────────────
//  HAUPT-API: Wählt optimale Methode, WP-Doktrin-Logik
//
//  Koordinaten-Konvention (GCI intern):
//    x = Ost, z = Nord, y = Höhe
//
//  Mapping von DCS (Eingabe via gci_lua.c):
//    DCS x (Nord) → GCI z
//    DCS y (Höhe) → GCI y
//    DCS z (Ost)  → GCI x
//
//  Rückgabe intercept_point ebenfalls in GCI-Koordinaten.
//  Rücktausch nach DCS erfolgt in gci_lua.c.
// ─────────────────────────────────────────────────────────────

InterceptSolution gci_compute_intercept(const AircraftState *f,
                                         const AircraftState *t) {
    InterceptSolution sol;
    memset(&sol, 0, sizeof(sol));

    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;
    sol.range        = gci_vec2_len(dx, dz);
    sol.aspect_angle = gci_aspect_angle(t, f);

    // Waffenfreigabe: innerhalb Radar-Lock-Reichweite (aspektunabhängig —
    // R-27R/ER ermöglicht Front-Quarter-Schuss, Aspekt wird vom Piloten beurteilt).
    // Projektion: Wenn der Jäger die WF-Grenze innerhalb des nächsten Ticks
    // (GCI_TICK_INTERVAL) erreicht, wird WF sofort gesetzt, damit die Freigabe
    // nicht eine volle Runde zu spät kommt.
    float closure          = gci_closure_rate(f, t);
    float projected_range  = sol.range - closure * GCI_TICK_INTERVAL;
    sol.weapons_free = (sol.range < GCI_WF_RANGE_MAX) ||
                       (closure > 0.0f && projected_range < GCI_WF_RANGE_MAX);

    // Versuch 1: Collision Course (optimal)
    // intercept_point inkl. Look-Down Offset wird in gci_solve_collision gesetzt
    if (gci_solve_collision(f, t,
                            &sol.heading_deg,
                            &sol.time_to_intercept,
                            &sol.intercept_point)) {
        sol.solution_found = true;
        sol.mode = PURSUIT_COLLISION;
        return sol;
    }

    // Versuch 2: Lead Pursuit (Jäger etwas zu langsam)
    gci_solve_lead(f, t, &sol.heading_deg, &sol.time_to_intercept);
    sol.solution_found = true;
    sol.mode = PURSUIT_LEAD;

    // Intercept-Punkt approximieren: Zielposition + Velocity × TTI
    // Look-Down Offset direkt hier addieren
    sol.intercept_point.x = t->pos.x + t->vel.x * sol.time_to_intercept;
    sol.intercept_point.z = t->pos.z + t->vel.z * sol.time_to_intercept;
    sol.intercept_point.y = t->pos.y + GCI_ALT_OFFSET_LOOKDOWN;
    /* vel.y weglassen — vertikale Bewegung für TTI-Approximation ignorieren */

    return sol;
}


// ─────────────────────────────────────────────────────────────
//  2v2 TAKTIK-SPLIT RECHNER
//
//  Koordinatensystem: GCI-intern (x=Ost, z=Nord, y=Höhe)
//
//  Gemeinsame Geometrie:
//    Formationsmitte → Ziel ergibt den Angriffsvektor (ax, az).
//    Senkrechter Vektor (90° links): px=-az, pz=ax.
//    "variation" skaliert die taktischen Spreizabstände, damit
//    kein Angriff identisch aussieht.
//
//  Minimalhöhe: 300 m MSL (alle Ausgabe-WPs geclampt).
// ─────────────────────────────────────────────────────────────

static void clamp_alt(Vec3 *v) {
    if (v->y < 300.0f) v->y = 300.0f;
}

TacticSplitPlan gci_compute_split(
    const AircraftState *f1,
    const AircraftState *f2,
    float tgt_x, float tgt_z, float tgt_y,
    TacticType  tactic,
    float       variation)
{
    TacticSplitPlan plan;
    memset(&plan, 0, sizeof(plan));
    plan.tactic = tactic;

    // ── Formationsmitte ──────────────────────────────────────
    float mid_x = (f1->pos.x + f2->pos.x) * 0.5f;
    float mid_z = (f1->pos.z + f2->pos.z) * 0.5f;

    // ── Normierter Angriffsvektor Mitte → Ziel ───────────────
    float dx  = tgt_x - mid_x;
    float dz  = tgt_z - mid_z;
    float rng = gci_vec2_len(dx, dz);
    if (rng < 1.0f) rng = 1.0f;
    float ax = dx / rng;   // Angriffsvektor x (Ost)
    float az = dz / rng;   // Angriffsvektor z (Nord)

    // ── Senkrechter Vektor (90° links) ───────────────────────
    float px = -az;
    float pz =  ax;

    switch (tactic) {

        // ── ZANGE: laterale Einhüllung ────────────────────────
        case TACTIC_PINCER: {
            // Spreizung 8–12 km je nach Variation
            float spread   = 8000.0f + variation * 4000.0f;
            // WP liegt 65 % des Weges zwischen Formation und Ziel
            float approach = rng * 0.65f;
            float merge_off = spread * 0.20f;  // leichter Versatz am Merge

            plan.wp_f1.x = mid_x + ax * approach + px * spread;
            plan.wp_f1.z = mid_z + az * approach + pz * spread;
            plan.wp_f1.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            plan.wp_f2.x = mid_x + ax * approach - px * spread;
            plan.wp_f2.z = mid_z + az * approach - pz * spread;
            plan.wp_f2.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            // Merge: beide konvergieren auf Zielpunkt, leicht seitlich
            plan.merge_f1.x = tgt_x + px * merge_off;
            plan.merge_f1.z = tgt_z + pz * merge_off;
            plan.merge_f1.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            plan.merge_f2.x = tgt_x - px * merge_off;
            plan.merge_f2.z = tgt_z - pz * merge_off;
            plan.merge_f2.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;
            break;
        }

        // ── HOCH-TIEF: vertikale Trennung ─────────────────────
        case TACTIC_HIGH_LOW: {
            float vert     = 3000.0f + variation * 1000.0f;  // 3–4 km
            float approach = rng * 0.70f;

            // f1: tief (Shootup-Geometrie)
            plan.wp_f1.x = mid_x + ax * approach;
            plan.wp_f1.z = mid_z + az * approach;
            plan.wp_f1.y = tgt_y - 400.0f;

            // f2: hoch (Shootdown-Geometrie)
            plan.wp_f2.x = mid_x + ax * approach;
            plan.wp_f2.z = mid_z + az * approach;
            plan.wp_f2.y = tgt_y + vert;

            // Merge: gleiche x/z wie Ziel, individuelle Höhen beibehalten
            plan.merge_f1.x = plan.merge_f2.x = tgt_x;
            plan.merge_f1.z = plan.merge_f2.z = tgt_z;
            plan.merge_f1.y = plan.wp_f1.y;
            plan.merge_f2.y = plan.wp_f2.y;
            break;
        }

        // ── STAFFEL: BVR-Führung + BVR-Support ────────────────
        case TACTIC_STAGGER: {
            float lag = 12000.0f + variation * 3000.0f;  // 12–15 km

            // f1: primärer Intercept (BVR-Führung)
            plan.wp_f1.x = tgt_x;
            plan.wp_f1.z = tgt_z;
            plan.wp_f1.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            // f2: gestaffelt zurück (BVR-Support, Folgeschuss)
            plan.wp_f2.x = tgt_x - ax * lag;
            plan.wp_f2.z = tgt_z - az * lag;
            plan.wp_f2.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            plan.merge_f1 = plan.wp_f1;
            plan.merge_f2 = plan.wp_f2;
            break;
        }

        // ── TRAIL: enger Heckangriff ───────────────────────────
        case TACTIC_TRAIL: {
            float lag = 3000.0f + variation * 2000.0f;  // 3–5 km

            plan.wp_f1.x = tgt_x;
            plan.wp_f1.z = tgt_z;
            plan.wp_f1.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            plan.wp_f2.x = tgt_x - ax * lag;
            plan.wp_f2.z = tgt_z - az * lag;
            plan.wp_f2.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;

            plan.merge_f1 = plan.wp_f1;
            plan.merge_f2 = plan.wp_f2;
            break;
        }

        // ── Fallback: beide direkt auf Ziel ───────────────────
        default: {
            plan.wp_f1.x = plan.wp_f2.x = tgt_x;
            plan.wp_f1.z = plan.wp_f2.z = tgt_z;
            plan.wp_f1.y = plan.wp_f2.y = tgt_y + GCI_ALT_OFFSET_LOOKDOWN;
            plan.merge_f1 = plan.wp_f1;
            plan.merge_f2 = plan.wp_f2;
            break;
        }
    }

    // Sicherheitscheck: 300 m Mindesthöhe MSL
    clamp_alt(&plan.wp_f1);
    clamp_alt(&plan.wp_f2);
    clamp_alt(&plan.merge_f1);
    clamp_alt(&plan.merge_f2);

    return plan;
}
