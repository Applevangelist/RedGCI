#ifndef MESSAGE_HANDLER_H
#define MESSAGE_HANDLER_H

#include "gci_types.h"

// ─────────────────────────────────────────────────────────────
//  UDP-Nachrichtenformat (Text-basiert, einfach zu debuggen)
//
//  Client → Server:
//    "INTERCEPT|fx|fz|fy|fspd|tx|tz|ty|tspd|tvx|tvz|tvy"
//    "PILOT_RADAR|flight_id|1"       Pilot meldet Lock
//    "PILOT_VISUAL|flight_id|1"      Pilot meldet Sicht
//    "PILOT_THREAT|flight_id|1"      RWR-Warnung
//    "FUEL|flight_id|0.45"           Sprit-Update
//    "PING"                          Verbindungstest
//
//  Server → Client:
//    "HDG:275|TTI:143|MODE:0|WF:1|STATE:1|RU:Курс 275...|EN:..."
//    "SILENCE"                       GCI schweigt
//    "PONG"
//    "ERR:msg"
// ─────────────────────────────────────────────────────────────

// Nachricht verarbeiten, Antwort in out schreiben
// Gibt 0 bei Erfolg zurück
int gci_process_message(const char *msg, char *out, int out_len);

// Session-State zurücksetzen (für neue Mission)
void gci_session_reset(void);

#endif
