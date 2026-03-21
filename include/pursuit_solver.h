#ifndef PURSUIT_SOLVER_H
#define PURSUIT_SOLVER_H

#include "gci_types.h"

// Hauptfunktion: wählt automatisch beste Methode
InterceptSolution gci_compute_intercept(
    const AircraftState *fighter,
    const AircraftState *target
);

// Einzelne Methoden (für Tests)
bool  gci_solve_collision(const AircraftState *f, const AircraftState *t,
                          float *hdg, float *tti, Vec3 *ip);
void  gci_solve_lead     (const AircraftState *f, const AircraftState *t,
                          float *hdg, float *tti);
void  gci_solve_pure     (const AircraftState *f, const AircraftState *t,
                          float *hdg, float *tti);

// Geometrie-Helfer
float gci_aspect_angle   (const AircraftState *target,
                          const AircraftState *observer);
float gci_closure_rate   (const AircraftState *f, const AircraftState *t);

// ─────────────────────────────────────────────────────────────
//  2v2 Taktik-Split-Rechner
//
//  Berechnet Split- und Merge-Einflugpunkte für zwei Fighter
//  gegen einen Ziel-Mittelpunkt.  Einmalig bei COMMIT aufgerufen;
//  Lua passt den merge_f1/f2-Punkt jeden Tick dynamisch nach.
//
//  Koordinaten: GCI-intern (x=Ost, z=Nord, y=Höhe)
//  tactic:    TACTIC_PINCER | HIGH_LOW | STAGGER | TRAIL
//  variation: 0.0–1.0 (Zufallsanteil für Unberechenbarkeit)
// ─────────────────────────────────────────────────────────────
TacticSplitPlan gci_compute_split(
    const AircraftState *f1,
    const AircraftState *f2,
    float tgt_x, float tgt_z, float tgt_y,
    TacticType  tactic,
    float       variation);

#endif
