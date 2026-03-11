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

#endif
