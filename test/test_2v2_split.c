#include <stdio.h>
#include <math.h>
#include <string.h>
#include <assert.h>
#include "pursuit_solver.h"

static int tests_run = 0, tests_passed = 0;

#define CHECK(cond, name) do { \
    tests_run++; \
    if(cond){tests_passed++;printf("  \xE2\x9C\x93  %s\n",name);} \
    else printf("  \xE2\x9C\x97  %s  (FAILED line %d)\n",name,__LINE__); \
} while(0)
#define CHECK_NEAR(a,b,tol,name) CHECK(fabsf((a)-(b))<(tol),name)
#define CHECK_GT(a,b,name)       CHECK((a)>(b),name)
#define CHECK_LT(a,b,name)       CHECK((a)<(b),name)

// ─────────────────────────────────────────────────────────────
//  Hilfsfunktionen
// ─────────────────────────────────────────────────────────────

static AircraftState make_ac(float gci_x, float gci_z, float y) {
    AircraftState a; memset(&a, 0, sizeof(a));
    a.pos.x = gci_x;
    a.pos.z = gci_z;
    a.pos.y = y;
    return a;
}

// Horizontaler Abstand zweier Vec3 (GCI-Koordinaten)
static float horiz_dist(Vec3 a, Vec3 b) {
    float dx = a.x - b.x;
    float dz = a.z - b.z;
    return sqrtf(dx*dx + dz*dz);
}

// ─────────────────────────────────────────────────────────────
//  Szenario: Formation fliegt Nord (0,0) → Ziel (0,40000)
//  f1 bei (-1000, 0), f2 bei (+1000, 0), beide auf 5000m MSL
//  Ziel: x=0, z=40000, y=6000m
// ─────────────────────────────────────────────────────────────

static void test_pincer(void) {
    printf("\n-- TACTIC_PINCER --\n");

    AircraftState f1 = make_ac(-1000.0f,     0.0f, 5000.0f);
    AircraftState f2 = make_ac( 1000.0f,     0.0f, 5000.0f);
    float tgt_x = 0.0f, tgt_z = 40000.0f, tgt_y = 6000.0f;

    TacticSplitPlan p = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y,
        TACTIC_PINCER, 0.5f);

    CHECK(p.tactic == TACTIC_PINCER, "Taktik korrekt gesetzt");

    // f1 muss links vom Angriffsvektor sein (GCI x < 0)
    CHECK(p.wp_f1.x < 0.0f, "PINCER: f1 links (x < 0)");
    // f2 muss rechts sein (GCI x > 0)
    CHECK(p.wp_f2.x > 0.0f, "PINCER: f2 rechts (x > 0)");

    // Laterale Spreizung: 8–12 km (variation=0.5 → 10 km)
    float sep = fabsf(p.wp_f1.x - p.wp_f2.x);
    CHECK_GT(sep, 8000.0f, "PINCER: Spreizung > 8 km");
    CHECK_LT(sep, 35000.0f, "PINCER: Spreizung < 35 km (inkl. formation-Offset)");

    // WP sollte zwischen Formation und Ziel liegen (z im Bereich 0..40000)
    CHECK_GT(p.wp_f1.z, 0.0f,     "PINCER: wp_f1.z > Startposition");
    CHECK_LT(p.wp_f1.z, 40000.0f, "PINCER: wp_f1.z < Zielposition");

    // Merge-Punkte näher am Ziel als Split-Punkte
    float d_split_f1  = fabsf(tgt_z - p.wp_f1.z);
    float d_merge_f1  = fabsf(tgt_z - p.merge_f1.z);
    CHECK_LT(d_merge_f1, d_split_f1, "PINCER: merge_f1 naeher am Ziel als wp_f1");

    // Mindesthöhe 300 m
    CHECK_GT(p.wp_f1.y,    299.9f, "PINCER: wp_f1 Mindesthoehe OK");
    CHECK_GT(p.wp_f2.y,    299.9f, "PINCER: wp_f2 Mindesthoehe OK");
    CHECK_GT(p.merge_f1.y, 299.9f, "PINCER: merge_f1 Mindesthoehe OK");

    printf("  -> wp_f1: (%.0f, %.0f) %.0fm  | wp_f2: (%.0f, %.0f) %.0fm\n",
        p.wp_f1.x, p.wp_f1.z, p.wp_f1.y,
        p.wp_f2.x, p.wp_f2.z, p.wp_f2.y);
    printf("  -> merge_f1: (%.0f, %.0f)  | merge_f2: (%.0f, %.0f)\n",
        p.merge_f1.x, p.merge_f1.z, p.merge_f2.x, p.merge_f2.z);
}

static void test_high_low(void) {
    printf("\n-- TACTIC_HIGH_LOW --\n");

    AircraftState f1 = make_ac(-1000.0f, 0.0f, 5000.0f);
    AircraftState f2 = make_ac( 1000.0f, 0.0f, 5000.0f);
    float tgt_x = 0.0f, tgt_z = 40000.0f, tgt_y = 6000.0f;

    TacticSplitPlan p = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y,
        TACTIC_HIGH_LOW, 0.5f);

    CHECK(p.tactic == TACTIC_HIGH_LOW, "Taktik korrekt gesetzt");

    // f2 muss höher sein als f1
    CHECK_GT(p.wp_f2.y, p.wp_f1.y, "HIGH_LOW: f2 hoeher als f1");

    // Vertikale Trennung: 3–4 km (variation=0.5 → 3.5 km) + ~400m Tiefversatz
    float vert = p.wp_f2.y - p.wp_f1.y;
    CHECK_GT(vert, 2500.0f, "HIGH_LOW: Vertikaltrennung > 2.5 km");
    CHECK_LT(vert, 5000.0f, "HIGH_LOW: Vertikaltrennung < 5 km");

    // Seitlicher Versatz für KI-Deconfliction (±2km) — nicht mehr gleiche Spur
    float side = fabsf(p.wp_f1.x - p.wp_f2.x);
    CHECK_GT(side, 1000.0f, "HIGH_LOW: seitlicher Versatz > 1 km");
    CHECK_LT(side, 5000.0f, "HIGH_LOW: seitlicher Versatz < 5 km");
    CHECK_NEAR(p.wp_f1.z, p.wp_f2.z, 50.0f, "HIGH_LOW: gleiche z-Spur");

    // Merge: 3 km vor Ziel (nicht direkt am Ziel)
    CHECK_LT(p.merge_f1.z, tgt_z, "HIGH_LOW: merge_f1.z vor Ziel");
    CHECK_GT(p.merge_f1.z, tgt_z - 5000.0f, "HIGH_LOW: merge_f1.z nicht zu weit vor Ziel");

    // Mindesthöhe
    CHECK_GT(p.wp_f1.y, 299.9f, "HIGH_LOW: wp_f1 Mindesthoehe OK");

    printf("  -> wp_f1: %.0fm  |  wp_f2: %.0fm  (Diff: %.0fm)\n",
        p.wp_f1.y, p.wp_f2.y, p.wp_f2.y - p.wp_f1.y);
}

static void test_stagger(void) {
    printf("\n-- TACTIC_STAGGER --\n");

    AircraftState f1 = make_ac(-1000.0f, 0.0f, 5000.0f);
    AircraftState f2 = make_ac( 1000.0f, 0.0f, 5000.0f);
    float tgt_x = 0.0f, tgt_z = 40000.0f, tgt_y = 6000.0f;

    TacticSplitPlan p = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y,
        TACTIC_STAGGER, 0.5f);

    CHECK(p.tactic == TACTIC_STAGGER, "Taktik korrekt gesetzt");

    // f1 bei 85% des Weges (0.85 * 40000 = 34000)
    CHECK_NEAR(p.wp_f1.x, tgt_x, 50.0f, "STAGGER: wp_f1.x = tgt_x");
    CHECK_NEAR(p.wp_f1.z, 34000.0f, 1000.0f, "STAGGER: wp_f1.z ~ 85% des Weges");

    // f2 muss hinter f1 sein (kleiner z-Wert = weiter weg)
    CHECK_LT(p.wp_f2.z, p.wp_f1.z, "STAGGER: wp_f2 hinter wp_f1");

    // Abstand f1–f2: 8–11 km (variation=0.5 → 9.5 km)
    float lag = horiz_dist(p.wp_f1, p.wp_f2);
    CHECK_GT(lag, 7000.0f,  "STAGGER: Abstand > 7 km");
    CHECK_LT(lag, 16000.0f, "STAGGER: Abstand < 16 km");

    printf("  -> wp_f1.z=%.0f  wp_f2.z=%.0f  lag=%.0fm\n",
        p.wp_f1.z, p.wp_f2.z, lag);
}

static void test_trail(void) {
    printf("\n-- TACTIC_TRAIL --\n");

    AircraftState f1 = make_ac(-1000.0f, 0.0f, 5000.0f);
    AircraftState f2 = make_ac( 1000.0f, 0.0f, 5000.0f);
    float tgt_x = 0.0f, tgt_z = 40000.0f, tgt_y = 6000.0f;

    TacticSplitPlan p = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y,
        TACTIC_TRAIL, 0.5f);

    CHECK(p.tactic == TACTIC_TRAIL, "Taktik korrekt gesetzt");

    // f2 hinter f1
    CHECK_LT(p.wp_f2.z, p.wp_f1.z, "TRAIL: wp_f2 hinter wp_f1");

    // Engerer Abstand als STAGGER: 3–5 km
    float lag = horiz_dist(p.wp_f1, p.wp_f2);
    CHECK_GT(lag, 2000.0f,  "TRAIL: Abstand > 2 km");
    CHECK_LT(lag, 6000.0f,  "TRAIL: Abstand < 6 km");

    printf("  -> wp_f1.z=%.0f  wp_f2.z=%.0f  lag=%.0fm\n",
        p.wp_f1.z, p.wp_f2.z, lag);
}

// ─────────────────────────────────────────────────────────────
//  Variation: gleiche Taktik, unterschiedliche Seeds → verschiedene WPs
// ─────────────────────────────────────────────────────────────

static void test_variation(void) {
    printf("\n-- Variation (Unberechenbarkeit) --\n");

    AircraftState f1 = make_ac(-1000.0f, 0.0f, 5000.0f);
    AircraftState f2 = make_ac( 1000.0f, 0.0f, 5000.0f);
    float tgt_x = 0.0f, tgt_z = 40000.0f, tgt_y = 6000.0f;

    TacticSplitPlan p0 = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y, TACTIC_PINCER, 0.0f);
    TacticSplitPlan p1 = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y, TACTIC_PINCER, 1.0f);

    // Spreizung bei variation=1.0 muss größer sein als bei variation=0.0
    float sep0 = fabsf(p0.wp_f1.x - p0.wp_f2.x);
    float sep1 = fabsf(p1.wp_f1.x - p1.wp_f2.x);
    CHECK_GT(sep1, sep0, "Variation: groessere Spreizung bei variation=1.0");

    // Spreizungsdifferenz: 2×5000 = 10 km (variation 0→1 skaliert spread um 5km pro Seite)
    CHECK_NEAR(sep1 - sep0, 10000.0f, 500.0f, "Variation: Spreizungsdelta ~ 10 km");

    printf("  -> sep(var=0.0): %.0fm  |  sep(var=1.0): %.0fm\n", sep0, sep1);

    // STAGGER: Abstand ändert sich mit Variation
    TacticSplitPlan s0 = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y, TACTIC_STAGGER, 0.0f);
    TacticSplitPlan s1 = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y, TACTIC_STAGGER, 1.0f);
    float lag0 = horiz_dist(s0.wp_f1, s0.wp_f2);
    float lag1 = horiz_dist(s1.wp_f1, s1.wp_f2);
    CHECK_GT(lag1, lag0, "Variation STAGGER: groesserer Abstand bei variation=1.0");
    printf("  -> lag(var=0.0): %.0fm  |  lag(var=1.0): %.0fm\n", lag0, lag1);
}

// ─────────────────────────────────────────────────────────────
//  Minimalhöhe: Ziel knapp über Boden → WPs dürfen nicht < 300m
// ─────────────────────────────────────────────────────────────

static void test_min_altitude(void) {
    printf("\n-- Mindesthoehe (Tiefflieger-Ziel) --\n");

    AircraftState f1 = make_ac(-1000.0f, 0.0f, 200.0f);
    AircraftState f2 = make_ac( 1000.0f, 0.0f, 200.0f);
    // Ziel sehr niedrig (HIGH_LOW: f1 soll noch tiefer → wird geclampt)
    float tgt_y = 500.0f;

    TacticSplitPlan p = gci_compute_split(&f1, &f2,
        0.0f, 40000.0f, tgt_y,
        TACTIC_HIGH_LOW, 0.5f);

    CHECK_GT(p.wp_f1.y,    299.9f, "Tiefflieger HIGH_LOW: wp_f1 >= 300m");
    CHECK_GT(p.wp_f2.y,    299.9f, "Tiefflieger HIGH_LOW: wp_f2 >= 300m");
    CHECK_GT(p.merge_f1.y, 299.9f, "Tiefflieger HIGH_LOW: merge_f1 >= 300m");
    CHECK_GT(p.merge_f2.y, 299.9f, "Tiefflieger HIGH_LOW: merge_f2 >= 300m");

    printf("  -> wp_f1.y=%.0f  wp_f2.y=%.0f\n", p.wp_f1.y, p.wp_f2.y);
}

// ─────────────────────────────────────────────────────────────
//  Seitliches Ziel: Angriffsvektor nicht Nord, sondern Ost
// ─────────────────────────────────────────────────────────────

static void test_east_attack(void) {
    printf("\n-- Ostangriff (Angriffsvektor 90 Grad) --\n");

    // Formation mittig, Ziel im Osten
    AircraftState f1 = make_ac(  0.0f, -1000.0f, 5000.0f);
    AircraftState f2 = make_ac(  0.0f,  1000.0f, 5000.0f);
    float tgt_x = 40000.0f, tgt_z = 0.0f, tgt_y = 6000.0f;

    TacticSplitPlan p = gci_compute_split(&f1, &f2,
        tgt_x, tgt_z, tgt_y,
        TACTIC_PINCER, 0.5f);

    // Angriffsvektor nach Ost (ax=1, az=0)
    // 90°-links-Perp: px=-az=0, pz=ax=1  → zeigt Nord
    // f1 bekommt +perp → Norden (z > 0)
    // f2 bekommt -perp → Süden  (z < 0)
    CHECK(p.wp_f1.z > 0.0f, "Ostangriff PINCER: f1 noerdlich (z > 0)");
    CHECK(p.wp_f2.z < 0.0f, "Ostangriff PINCER: f2 suedlich (z < 0)");

    printf("  -> wp_f1.z=%.0f  wp_f2.z=%.0f\n", p.wp_f1.z, p.wp_f2.z);
}

// ─────────────────────────────────────────────────────────────
//  Target-Assignment: greedy 2×2 nach kürzester Gesamtstrecke
// ─────────────────────────────────────────────────────────────

static void test_target_assignment(void) {
    printf("\n-- Target Assignment (greedy 2x2) --\n");

    // f1 im Westen, f2 im Osten
    // t1 im Westen (näher an f1), t2 im Osten (näher an f2)
    // Direkte Zuweisung sollte günstiger sein als gekreuzte.

    // Positionen in GCI-Koordinaten (x=Ost, z=Nord)
    float f1x = -15000.0f, f1z = 0.0f;   // West
    float f2x =  15000.0f, f2z = 0.0f;   // Ost
    float t1x = -10000.0f, t1z = 40000.0f; // NW (näher an f1)
    float t2x =  10000.0f, t2z = 40000.0f; // NO (näher an f2)

    // Rangeberechnung für alle 4 Kombinationen
    float r_f1t1 = sqrtf((t1x-f1x)*(t1x-f1x) + (t1z-f1z)*(t1z-f1z));
    float r_f2t2 = sqrtf((t2x-f2x)*(t2x-f2x) + (t2z-f2z)*(t2z-f2z));
    float r_f1t2 = sqrtf((t2x-f1x)*(t2x-f1x) + (t2z-f1z)*(t2z-f1z));
    float r_f2t1 = sqrtf((t1x-f2x)*(t1x-f2x) + (t1z-f2z)*(t1z-f2z));

    float cost_direct  = r_f1t1 + r_f2t2;
    float cost_crossed = r_f1t2 + r_f2t1;

    CHECK_LT(cost_direct, cost_crossed,
        "Assignment: direkte Zuweisung guenstiger als gekreuzte");
    printf("  -> direkt: %.0fm  |  gekreuzt: %.0fm\n", cost_direct, cost_crossed);

    // Umgekehrter Fall: f1 und f2 tauschen → gekreuzte Zuweisung besser
    float r2_f1t1 = sqrtf((t1x-f2x)*(t1x-f2x) + (t1z-f2z)*(t1z-f2z));
    float r2_f2t2 = sqrtf((t2x-f1x)*(t2x-f1x) + (t2z-f1z)*(t2z-f1z));
    float cost_direct2  = r2_f1t1 + r2_f2t2;
    float cost_crossed2 = r_f1t1  + r_f2t2;
    CHECK_LT(cost_crossed2, cost_direct2,
        "Assignment (gekreuzt): jetzt gekreuzte Zuweisung guenstiger");
    printf("  -> direkt: %.0fm  |  gekreuzt: %.0fm\n", cost_direct2, cost_crossed2);
}

int main(void) {
    printf("==================================\n");
    printf("  2v2 Split Unit Tests\n");
    printf("==================================\n");

    test_pincer();
    test_high_low();
    test_stagger();
    test_trail();
    test_variation();
    test_min_altitude();
    test_east_attack();
    test_target_assignment();

    printf("\n==================================\n");
    printf("  Ergebnis: %d/%d Tests bestanden\n", tests_passed, tests_run);
    printf("==================================\n");
    return (tests_passed == tests_run) ? 0 : 1;
}
