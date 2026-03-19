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
}

static void test_weapons_free(void) {
    printf("\n-- Waffenfreigabe --\n");
    AircraftState f = make_ac(0,0,5000, 0, 250, 250);

    /* Innerhalb GCI_WF_RANGE_MAX (20 km): WF unabhaengig vom Aspekt */
    AircraftState t_close_tail = make_ac(0,14000,5700,  0,  220, 220);
    AircraftState t_close_nose = make_ac(0,14000,5700,  0, -220, 220);
    InterceptSolution s_ct = gci_compute_intercept(&f, &t_close_tail);
    InterceptSolution s_cn = gci_compute_intercept(&f, &t_close_nose);
    printf("  -> close tail WF:%d  close nose WF:%d\n",
           s_ct.weapons_free, s_cn.weapons_free);
    CHECK(s_ct.weapons_free == true, "WF bei Tail innerhalb 20km");
    CHECK(s_cn.weapons_free == true, "WF bei Nose-on innerhalb 20km (R-27R front-quarter)");

    /* Ausserhalb GCI_WF_RANGE_MAX (>= 25 km): kein WF */
    AircraftState t_far_tail = make_ac(0,24000,5700,  0,  220, 220);
    AircraftState t_far_nose = make_ac(0,24000,5700,  0, -220, 220);
    InterceptSolution s_ft = gci_compute_intercept(&f, &t_far_tail);
    InterceptSolution s_fn = gci_compute_intercept(&f, &t_far_nose);
    printf("  -> far  tail WF:%d  far  nose WF:%d\n",
           s_ft.weapons_free, s_fn.weapons_free);
    CHECK(s_ft.weapons_free == false, "Kein WF bei Tail ausserhalb 25km");
    CHECK(s_fn.weapons_free == false, "Kein WF bei Nose-on ausserhalb 25km");
}

int main(void) {
    printf("==================================\n");
    printf("  GCI POC -- Unit Tests\n");
    printf("==================================\n");
    test_aspect();
    test_collision_stationary();
    test_collision_crossing();
    test_fallback_lead();
    test_fsm();
    test_msg_handler();
    test_weapons_free();
    printf("\n==================================\n");
    printf("  Ergebnis: %d/%d Tests bestanden\n", tests_passed, tests_run);
    printf("==================================\n");
    return (tests_passed == tests_run) ? 0 : 1;
}
