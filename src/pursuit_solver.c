#include "pursuit_solver.h"
#include <string.h>
#include <stdlib.h>

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

    // Treffpunkt
    ip->x = t->pos.x + vtx * sol_t;
    ip->z = t->pos.z + vtz * sol_t;
    ip->y = t->pos.y + t->vel.y * sol_t;

    // Kurs zum Treffpunkt
    *hdg = gci_bearing(ip->x - f->pos.x, ip->z - f->pos.z);
    *tti = sol_t;
    return true;
}


// ─────────────────────────────────────────────────────────────
//  LEAD PURSUIT
//  Sinus-Regel: sin(lead) / |Vt| = sin(aspect_from_target) / |Vf|
// ─────────────────────────────────────────────────────────────

void gci_solve_lead(const AircraftState *f, const AircraftState *t,
                     float *hdg, float *tti) {
    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;
    float range = gci_vec2_len(dx, dz);
    if (range < 1.0f) { *hdg = 0.0f; *tti = 0.0f; return; }

    float base_bearing = gci_bearing(dx, dz);

    // Aspect vom Ziel aus gesehen (umgekehrt)
    AircraftState f_as_observer = *f;
    float aspect_rad = gci_aspect_angle(t, f) * GCI_DEG2RAD;

    float speed_ratio = (t->speed) / (f->speed + 1e-6f);
    float sin_lead = GCI_CLAMP(speed_ratio * sinf(aspect_rad), -1.0f, 1.0f);
    float lead_deg = asinf(sin_lead) * GCI_RAD2DEG;
    (void)f_as_observer;

    *hdg = fmodf(base_bearing + lead_deg + 360.0f, 360.0f);

    float closing = gci_closure_rate(f, t);
    *tti = range / (closing > 10.0f ? closing : 10.0f);
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
// ─────────────────────────────────────────────────────────────

InterceptSolution gci_compute_intercept(const AircraftState *f,
                                         const AircraftState *t) {
    InterceptSolution sol;
    memset(&sol, 0, sizeof(sol));

    float dx = t->pos.x - f->pos.x;
    float dz = t->pos.z - f->pos.z;
    sol.range        = gci_vec2_len(dx, dz);
    sol.aspect_angle = gci_aspect_angle(t, f);

    // WP-Doktrin: MiG-29 wird leicht über Ziel geführt (Look-Down)
    // Intercept-Höhe = Zielhöhe + 700m
    sol.intercept_point.y = t->pos.y + GCI_ALT_OFFSET_LOOKDOWN;

    // Waffenfreigabe: Heckaspekt UND innerhalb R-27 Reichweite
    sol.weapons_free = (sol.aspect_angle > GCI_ASPECT_REAR_ATTACK)
                    && (sol.range < GCI_WF_RANGE_MAX);

    // Versuch 1: Collision Course (optimal)
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

    // Pure Pursuit wird vom GCI nie ausgegeben —
    // bei fehlender Lösung würde er "Цель визуально" sagen
    // und den Piloten selbst handeln lassen.
    return sol;
}
