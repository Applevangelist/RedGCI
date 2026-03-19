#include <stdio.h>
#include <math.h>
#include <string.h>
#include <assert.h>
#include "pursuit_solver.h"
#include "intercept_fsm.h"
#include "message_handler.h"

static int tests_run = 0, tests_passed = 0;

#define CHECK(cond, name) do { \
    tests_run++; \
    if(cond){tests_passed++;printf("  \xE2\x9C\x93  %s\n",name);} \
    else printf("  \xE2\x9C\x97  %s  (FAILED line %d)\n",name,__LINE__); \
} while(0)
#define CHECK_NEAR(a,b,tol,name) CHECK(fabsf((a)-(b))<(tol),name)

static AircraftState make_ac(float x,float z,float y,float vx,float vz,float spd) {
    AircraftState a; memset(&a,0,sizeof(a));
    a.pos.x=x; a.pos.z=z; a.pos.y=y;
    a.vel.x=vx; a.vel.z=vz; a.speed=spd;
    return a;
}

static void test_aspect(void) {
    printf("\n-- Aspect Angle --\n");
    AircraftState t = make_ac(0,20000,5000, 0,-250, 250);
    AircraftState f = make_ac(0,0,5000, 0,0, 0);
    CHECK_NEAR(gci_aspect_angle(&t,&f), 0.0f, 5.0f, "Nose-on ~ 0 deg");
    t = make_ac(0,20000,5000, 0,220, 220);
    CHECK_NEAR(gci_aspect_angle(&t,&f), 180.0f, 5.0f, "Tail ~ 180 deg");
    t = make_ac(0,20000,5000, 250,0, 250);
    CHECK_NEAR(gci_aspect_angle(&t,&f), 90.0f, 10.0f, "Beam ~ 90 deg");
}

static void test_closure_rate(void) {
    printf("\n-- Closure Rate --\n");
    /* Ziel direkt vor Jaeger, beide naehern sich an */
    AircraftState f = make_ac(0,0,5000,   0,250,250);
    AircraftState t = make_ac(0,20000,5000, 0,-100,100);
    float cr = gci_closure_rate(&f, &t);
    CHECK(cr > 0.0f, "Annaeherung: Closure Rate positiv");
    CHECK_NEAR(cr, 350.0f, 20.0f, "Annaeherung ~ 350 m/s");

    /* Ziel entfernt sich (schneller als Jaeger) */
    AircraftState t2 = make_ac(0,20000,5000, 0,350,350);
    float cr2 = gci_closure_rate(&f, &t2);
    CHECK(cr2 < 0.0f, "Entfernung: Closure Rate negativ");

    /* Statisches Ziel */
    AircraftState t3 = make_ac(0,20000,5000, 0,0,0);
    float cr3 = gci_closure_rate(&f, &t3);
    CHECK_NEAR(cr3, 250.0f, 20.0f, "Statisches Ziel: CR ~ Jaegergeschwindigkeit");
}

static void test_collision_stationary(void) {
    printf("\n-- Collision (stationaer) --\n");
    AircraftState f = make_ac(0,0,5000,   0,250,250);
    AircraftState t = make_ac(0,20000,5000, 0,0,  0);
    float hdg,tti; Vec3 ip;
    bool ok = gci_solve_collision(&f,&t,&hdg,&tti,&ip);
    CHECK(ok, "Loesung gefunden");
    CHECK_NEAR(hdg, 0.0f, 2.0f, "Kurs ~ 0 deg (Nord)");
    CHECK_NEAR(tti, 80.0f, 5.0f, "TTI ~ 80s");
}

static void test_collision_crossing(void) {
    printf("\n-- Collision (kreuzendes Ziel) --\n");
    AircraftState f = make_ac(0,0,5000, 0,300,300);
    AircraftState t = make_ac(30000,5000,5000, 0,-200,200);
    float hdg,tti; Vec3 ip;
    bool ok = gci_solve_collision(&f,&t,&hdg,&tti,&ip);
    CHECK(ok, "Loesung gefunden");
    CHECK(hdg>80.0f && hdg<140.0f, "Lead-Kurs im Bereich");
    CHECK(tti>0 && tti<300, "TTI realistisch");
    printf("  -> Kurs:%.1f TTI:%.0fs\n",hdg,tti);
}

static void test_pure_pursuit(void) {
    printf("\n-- Pure Pursuit --\n");
    AircraftState f = make_ac(0,0,5000,   0,250,250);
    AircraftState t = make_ac(0,20000,5000, 0,0,  0);
    float hdg, tti;
    gci_solve_pure(&f, &t, &hdg, &tti);
    CHECK_NEAR(hdg, 0.0f, 2.0f, "Pure: Kurs direkt zum Ziel (Nord)");
    CHECK_NEAR(tti, 80.0f, 5.0f, "Pure: TTI ~ 80s");

    /* Ziel seitlich */
    AircraftState t2 = make_ac(10000,0,5000, 0,0,0);
    gci_solve_pure(&f, &t2, &hdg, &tti);
    CHECK_NEAR(hdg, 90.0f, 2.0f, "Pure: Kurs 90 deg (Ost)");
}

static void test_fallback_lead(void) {
    printf("\n-- Fallback Lead Pursuit --\n");
    AircraftState f = make_ac(0,0,5000, 0,100,100);
    AircraftState t = make_ac(20000,5000,5000, 200,0,200);
    InterceptSolution sol = gci_compute_intercept(&f,&t);
    CHECK(sol.solution_found, "Fallback-Loesung gefunden");
    CHECK(sol.mode==PURSUIT_LEAD||sol.mode==PURSUIT_COLLISION, "LEAD oder COLLISION");
    printf("  -> Mode:%s Kurs:%.1f\n",
        sol.mode==PURSUIT_COLLISION?"COLLISION":"LEAD", sol.heading_deg);
}

static void test_fsm(void) {
    printf("\n-- FSM Uebergaenge --\n");
    InterceptContext ctx; gci_context_init(&ctx);

    // VECTOR->COMMIT: Range < 30km (GCI_RANGE_COMMIT)
    gci_context_update(&ctx, 29000, 45, 80, -700, 0.8f);
    CHECK(gci_fsm_transition(&ctx)==STATE_COMMIT, "VECTOR->COMMIT <30km");

    ctx.state = STATE_COMMIT; ctx.pilot_has_radar = 1;
    gci_context_update(&ctx, 20000, 145, 100, -700, 0.8f);
    CHECK(gci_fsm_transition(&ctx)==STATE_RADAR_CONTACT, "COMMIT->RADAR_CONTACT");

    ctx.state = STATE_RADAR_CONTACT;
    gci_context_update(&ctx, 4500, 160, 120, -500, 0.7f);
    CHECK(gci_fsm_transition(&ctx)==STATE_VISUAL, "RADAR->VISUAL <5km");

    ctx.state = STATE_VISUAL;
    gci_context_update(&ctx, 1800, 170, 150, -200, 0.7f);
    CHECK(gci_fsm_transition(&ctx)==STATE_MERGE, "VISUAL->MERGE <2km");

    ctx.state = STATE_VECTOR; ctx.fuel_fraction = 0.2f;
    CHECK(gci_fsm_transition(&ctx)==STATE_ABORT, "ABORT bei Bingo");

    ctx.state = STATE_VECTOR; ctx.fuel_fraction = 0.8f;
    gci_context_update(&ctx, 45000, 90, 10, -700, 0.8f);
    CHECK(gci_fsm_transition(&ctx)==STATE_NOTCH, "VECTOR->NOTCH Beam");

    /* Threat Detection -> ABORT */
    ctx.state = STATE_VECTOR; ctx.threat_detected = 1;
    gci_context_update(&ctx, 15000, 45, 100, -500, 0.8f);
    CHECK(gci_fsm_transition(&ctx)==STATE_ABORT, "ABORT bei Threat (> VISUAL range)");
    ctx.threat_detected = 0;

    /* NOTCH -> VECTOR wenn Aspekt wieder normal */
    ctx.state = STATE_NOTCH;
    gci_context_update(&ctx, 30000, 45, 100, -500, 0.8f);
    CHECK(gci_fsm_transition(&ctx)==STATE_VECTOR, "NOTCH->VECTOR wenn Aspekt normal");

    /* Lock verloren: RADAR_CONTACT -> COMMIT */
    ctx.state = STATE_RADAR_CONTACT; ctx.pilot_has_radar = 0;
    gci_context_update(&ctx, 25000, 45, 100, -500, 0.8f);
    CHECK(gci_fsm_transition(&ctx)==STATE_COMMIT, "RADAR_CONTACT->COMMIT (Lock verloren)");
}

static void test_merge_controller(void) {
    printf("\n-- Merge Controller --\n");
    MergeContext ctx, prev;
    gci_merge_context_init(&ctx);
    gci_merge_context_init(&prev);

    /* Radar verloren -> LOST */
    ctx.radar_lost = true;
    CHECK(gci_merge_transition(&ctx, &prev)==MERGE_LOST, "Radar lost -> MERGE_LOST");
    ctx.radar_lost = false;

    /* Separation: Closure negativ und Range > 3km */
    ctx.closure_rate = -100.0f;
    ctx.range = 4000.0f;
    ctx.bearing_to_target = 30.0f;
    CHECK(gci_merge_transition(&ctx, &prev)==MERGE_SEPARATION, "Separation bei negativer Closure");

    /* Overshoot: Ziel hinter Jaeger und <5km */
    ctx.closure_rate = 50.0f;
    ctx.bearing_to_target = 180.0f;
    ctx.range = 2000.0f;
    CHECK(gci_merge_transition(&ctx, &prev)==MERGE_OVERSHOOT, "Overshoot bei Bearing ~180 <5km");

    /* Reattack: Separation mit pass_count < 3 */
    ctx.phase = MERGE_SEPARATION;
    ctx.pass_count = 1;
    ctx.closure_rate = -100.0f;
    ctx.range = 4000.0f;
    ctx.bearing_to_target = 30.0f;
    CHECK(gci_merge_transition(&ctx, &prev)==MERGE_SEPARATION, "Separation -> bleibt SEPARATION");

    /* Merge Transmission Test */
    GCITransmission tx;
    gci_merge_context_init(&ctx);
    gci_merge_context_init(&prev);
    ctx.bearing_to_target = 45.0f;
    ctx.range = 1500.0f;
    gci_build_merge_transmission(&ctx, &prev, "Sokol-1", &tx);
    CHECK(!tx.silence, "MERGE_ENTRY erzeugt Transmission");
    CHECK(strstr(tx.token_str,"MERGE_ENTRY")!=NULL, "Token enthaelt MERGE_ENTRY");
    printf("  -> Token: %.80s\n", tx.token_str);
}

static void test_msg_handler(void) {
    printf("\n-- Message Handler --\n");
    char resp[4096];
    gci_process_message("PING", resp, sizeof(resp));
    CHECK(strcmp(resp,"PONG")==0, "PING->PONG");
    gci_process_message("RESET", resp, sizeof(resp));
    CHECK(strncmp(resp,"OK:",3)==0, "RESET->OK");
    gci_process_message("INTERCEPT|0|0|5000|250|0|50000|5700|220|0|-220|0",
                        resp, sizeof(resp));
    CHECK(strstr(resp,"HDG:")!=NULL||strcmp(resp,"SILENCE")==0, "INTERCEPT->HDG/SILENCE");
    printf("  -> %.100s\n", resp);
    gci_process_message("GARBAGE", resp, sizeof(resp));
    CHECK(strncmp(resp,"ERR:",4)==0, "Ungueltig->ERR");

    /* Pilot-Status Nachrichten */
    gci_process_message("RESET", resp, sizeof(resp));
    gci_process_message("PILOT_RADAR|sokol|1", resp, sizeof(resp));
    CHECK(strncmp(resp,"OK:RADAR=",9)==0, "PILOT_RADAR->OK");

    gci_process_message("PILOT_VISUAL|sokol|1", resp, sizeof(resp));
    CHECK(strncmp(resp,"OK:VISUAL=",10)==0, "PILOT_VISUAL->OK");

    gci_process_message("PILOT_THREAT|sokol|1", resp, sizeof(resp));
    CHECK(strncmp(resp,"OK:THREAT=",10)==0, "PILOT_THREAT->OK");

    gci_process_message("FUEL|sokol|0.35", resp, sizeof(resp));
    CHECK(strncmp(resp,"OK:FUEL=",8)==0, "FUEL->OK");

    gci_process_message("MERGE_SPLASH", resp, sizeof(resp));
    CHECK(strstr(resp,"MERGE_SPLASH")!=NULL, "MERGE_SPLASH->Token");
    printf("  -> %.80s\n", resp);
}

static void test_weapons_free(void) {
    printf("\n-- Waffenfreigabe --\n");
    AircraftState f = make_ac(0,0,5000, 0, 250, 250);

    /* Innerhalb GCI_WF_RANGE_MAX (25 km): WF unabhaengig vom Aspekt */
    AircraftState t_close_tail = make_ac(0,14000,5700,  0,  220, 220);
    AircraftState t_close_nose = make_ac(0,14000,5700,  0, -220, 220);
    InterceptSolution s_ct = gci_compute_intercept(&f, &t_close_tail);
    InterceptSolution s_cn = gci_compute_intercept(&f, &t_close_nose);
    printf("  -> close tail WF:%d  close nose WF:%d\n",
           s_ct.weapons_free, s_cn.weapons_free);
    CHECK(s_ct.weapons_free == true, "WF bei Tail innerhalb 25km");
    CHECK(s_cn.weapons_free == true, "WF bei Nose-on innerhalb 25km (R-27ER front-quarter)");

    /* Ausserhalb GCI_WF_RANGE_MAX (>= 25 km): kein WF */
    AircraftState t_far_tail = make_ac(0,30000,5700,  0,  220, 220);
    AircraftState t_far_nose = make_ac(0,30000,5700,  0, -220, 220);
    InterceptSolution s_ft = gci_compute_intercept(&f, &t_far_tail);
    InterceptSolution s_fn = gci_compute_intercept(&f, &t_far_nose);
    printf("  -> far  tail WF:%d  far  nose WF:%d\n",
           s_ft.weapons_free, s_fn.weapons_free);
    CHECK(s_ft.weapons_free == false, "Kein WF bei Tail ausserhalb 25km");
    CHECK(s_fn.weapons_free == false, "Kein WF bei Nose-on ausserhalb 25km");

    /* Grenzfall: genau 25km (WF = false, da < nicht <=) */
    AircraftState t_boundary = make_ac(0,25000,5700,  0,  220, 220);
    InterceptSolution s_b = gci_compute_intercept(&f, &t_boundary);
    CHECK(s_b.weapons_free == false, "Kein WF genau an Grenze 25km");
}

int main(void) {
    printf("==================================\n");
    printf("  GCI POC -- Unit Tests\n");
    printf("==================================\n");
    test_aspect();
    test_closure_rate();
    test_collision_stationary();
    test_collision_crossing();
    test_pure_pursuit();
    test_fallback_lead();
    test_fsm();
    test_merge_controller();
    test_msg_handler();
    test_weapons_free();
    printf("\n==================================\n");
    printf("  Ergebnis: %d/%d Tests bestanden\n", tests_passed, tests_run);
    printf("==================================\n");
    return (tests_passed == tests_run) ? 0 : 1;
}
