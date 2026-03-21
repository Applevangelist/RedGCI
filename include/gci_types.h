#ifndef GCI_TYPES_H
#define GCI_TYPES_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

// ─────────────────────────────────────────────────────────────
//  Koordinatensystem: DCS World
//  x = Ost (+), z = Nord (+), y = Höhe (+)
//  Alle Distanzen in Metern, Geschwindigkeiten in m/s
//  Winkel in Grad, 0° = Nord, im Uhrzeigersinn
// ─────────────────────────────────────────────────────────────

typedef struct {
    float x, z;   // Horizontale Ebene
    float y;      // Höhe MSL
} Vec3;

typedef struct {
    Vec3  pos;
    Vec3  vel;
    float speed;   // Horizontaler Betrag (gecacht, m/s)
} AircraftState;

// ─────────────────────────────────────────────────────────────
//  Intercept-Lösung (Ausgabe des Pursuit Solvers)
// ─────────────────────────────────────────────────────────────

typedef enum {
    PURSUIT_COLLISION = 0,   // Optimal: CBDR Collision Course
    PURSUIT_LEAD      = 1,   // Vorhaltewinkel-basiert (Fallback)
    PURSUIT_PURE      = 2,   // Pure Pursuit (letzter Ausweg)
    PURSUIT_NO_SOLUTION = 3  // Keine Lösung möglich
} PursuitMode;

typedef struct {
    float       heading_deg;
    float       time_to_intercept;   // Sekunden
    Vec3        intercept_point;
    float       target_alt;          // Zielhöhe MSL in Metern (ohne Look-Down Offset)
    bool        solution_found;
    float       aspect_angle;        // 0=Nose-on, 180=Tail
    float       range;               // Aktuelle Distanz, Meter
    PursuitMode mode;
    bool        weapons_free;        // Waffenfreigabe-Empfehlung
} InterceptSolution;

// ─────────────────────────────────────────────────────────────
//  Intercept FSM Zustände
// ─────────────────────────────────────────────────────────────

typedef enum {
    STATE_VECTOR         = 0,
    STATE_COMMIT         = 1,
    STATE_RADAR_CONTACT  = 2,
    STATE_VISUAL         = 3,
    STATE_MERGE          = 4,
    STATE_NOTCH          = 5,
    STATE_ABORT          = 6,
    STATE_RTB            = 7
} InterceptState;

typedef enum {
    THREAT_NONE   = 0,
    THREAT_LOW    = 1,
    THREAT_MEDIUM = 2,
    THREAT_HIGH   = 3
} ThreatLevel;

// ─────────────────────────────────────────────────────────────
//  FSM Kontext — wird pro Intercept-Auftrag gehalten
// ─────────────────────────────────────────────────────────────

typedef struct {
    InterceptState state;
    InterceptState prev_state;
    float          range;
    float          aspect_angle;
    float          closure_rate;      // m/s, positiv = annähernd
    float          altitude_delta;    // Jäger minus Ziel, Meter
    float          fuel_fraction;     // 0.0–1.0
    bool           pilot_has_radar;
    bool           pilot_has_visual;
    bool           threat_detected;
    int            ticks_in_state;    // Takte in aktuellem Zustand
    int            pass_count;        // Merge-Pässe bisher
} InterceptContext;

// ─────────────────────────────────────────────────────────────
//  GCI Transmission — Ausgabe an Pilot
//  token_str Format: "KEY|k=v|k=v|..."
//  Beispiel: "VECTOR|hdg=165|alt=4500|tti_m=8|rng=62|delay=4.2"
// ─────────────────────────────────────────────────────────────

typedef struct {
    char  token_str[256];    // Token-String für Lua/MSRS
    float delay_sec;         // Realistische Funkverzögerung 3–8s
    bool  weapons_free;
    bool  silence;           // GCI sendet nichts
} GCITransmission;

// ─────────────────────────────────────────────────────────────
//  Merge Controller
// ─────────────────────────────────────────────────────────────

typedef enum {
    MERGE_ENTRY      = 0,
    MERGE_OVERSHOOT  = 1,
    MERGE_SEPARATION = 2,
    MERGE_REATTACK   = 3,
    MERGE_LOST       = 4,
    MERGE_SPLASH     = 5
} MergePhase;

typedef struct {
    MergePhase phase;
    float      range;
    float      bearing_to_target;
    float      altitude_delta;
    float      closure_rate;
    bool       radar_lost;
    int        pass_count;
    int        ticks_in_phase;
} MergeContext;

// ─────────────────────────────────────────────────────────────
//  Konstanten (historisch kalibriert für MiG-29A / 1985)
// ─────────────────────────────────────────────────────────────

#define GCI_RANGE_VECTOR_START   60000.0f   // 60km  – Erste Vektierung
#define GCI_RANGE_COMMIT         30000.0f   // 30km  – Radar einschalten
#define GCI_RANGE_RADAR_FLOOR    20000.0f   // 20km  – Lock erwartet
#define GCI_RANGE_VISUAL          5000.0f   //  5km  – Sicht erwartet
#define GCI_RANGE_MERGE           2000.0f   //  2km  – Merge

#define GCI_ALT_OFFSET_LOOKDOWN      0.0f   // Meter über Ziel (Look-Down)
#define GCI_ASPECT_NOTCH_MIN        80.0f   // Grad – Notch-Bereich
#define GCI_ASPECT_NOTCH_MAX       100.0f
#define GCI_ASPECT_REAR_ATTACK     120.0f   // Heckschuss-Aspekt

#define GCI_FUEL_BINGO              0.25f   // 25% – Rückkehr
#define GCI_WF_RANGE_MAX          25000.0f  // Waffenfreigabe-Range (R-27ER effective BVR)
#define GCI_MAX_TTI                 600.0f  // 10 Minuten – Limit

#define GCI_DELAY_MIN               3.0f    // Funkverzögerung Sekunden
#define GCI_DELAY_MAX               8.0f
#define GCI_DELAY_MERGE_MIN         2.0f    // Schneller im Merge
#define GCI_DELAY_MERGE_MAX         4.0f

#define GCI_TICK_INTERVAL          15.0f    // SRS-Tick in Sekunden

// ─────────────────────────────────────────────────────────────
//  2v2 Taktik-Typen und Split-Plan
//  Wird bei COMMIT berechnet und pro Tick nachgeführt.
// ─────────────────────────────────────────────────────────────

typedef enum {
    TACTIC_PINCER   = 0,  // Zange: laterale Einhüllung (links/rechts)
    TACTIC_HIGH_LOW = 1,  // Hoch-Tief: vertikale Trennung
    TACTIC_STAGGER  = 2,  // Staffel: BVR-Führung + 12–15 km Abstand
    TACTIC_TRAIL    = 3,  // Trail: enger Heckangriff 3–5 km
} TacticType;

typedef struct {
    Vec3       wp_f1;      // Split-Wegpunkt Fighter 1 (GCI-Koordinaten)
    Vec3       wp_f2;      // Split-Wegpunkt Fighter 2 (GCI-Koordinaten)
    Vec3       merge_f1;   // Merge-Einflugpunkt Fighter 1
    Vec3       merge_f2;   // Merge-Einflugpunkt Fighter 2
    TacticType tactic;
} TacticSplitPlan;

// ─────────────────────────────────────────────────────────────
//  Hilfsmakros
// ─────────────────────────────────────────────────────────────

#define GCI_PI        3.14159265358979f
#define GCI_RAD2DEG   (180.0f / GCI_PI)
#define GCI_DEG2RAD   (GCI_PI / 180.0f)
#define GCI_CLAMP(v,lo,hi) ((v)<(lo)?(lo):((v)>(hi)?(hi):(v)))

static inline float gci_vec2_len(float x, float z) {
    return sqrtf(x*x + z*z);
}

static inline float gci_bearing(float dx, float dz) {
    float b = atan2f(dx, dz) * GCI_RAD2DEG;
    return (b < 0.0f) ? b + 360.0f : b;
}

static inline float gci_randf(float lo, float hi) {
    return lo + ((float)(rand() % 1000) / 1000.0f) * (hi - lo);
}

#endif /* GCI_TYPES_H */
