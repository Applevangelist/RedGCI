cmake_minimum_required(VERSION 3.16)
project(gci_poc C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ─────────────────────────────────────────────────────────────
#  Build-Optionen
# ─────────────────────────────────────────────────────────────
option(BUILD_TESTS     "Build unit tests"         ON)
option(BUILD_SERVER    "Build UDP server (EXE)"   ON)

# Optimierung
if(MSVC)
    add_compile_options(/O2 /W3)
else()
    add_compile_options(-O2 -Wall -Wextra)
endif()

# ─────────────────────────────────────────────────────────────
#  Gemeinsame Kern-Bibliothek (statisch)
#  Wird von Server UND Tests gelinkt
# ─────────────────────────────────────────────────────────────
add_library(gci_core STATIC
    src/pursuit_solver.c
    src/intercept_fsm.c
    src/merge_controller.c
    src/message_handler.c
)
target_include_directories(gci_core PUBLIC include)
target_link_libraries(gci_core m)   # libm für math.h

# ─────────────────────────────────────────────────────────────
#  UDP Server (Windows: +ws2_32)
# ─────────────────────────────────────────────────────────────
if(BUILD_SERVER)
    add_executable(gci_server src/gci_server.c)
    target_link_libraries(gci_server gci_core)

    if(WIN32)
        target_link_libraries(gci_server ws2_32)
    endif()
endif()

# ─────────────────────────────────────────────────────────────
#  Unit Tests
# ─────────────────────────────────────────────────────────────
if(BUILD_TESTS)
    enable_testing()
    add_executable(gci_tests test/test_pursuit.c)
    target_link_libraries(gci_tests gci_core)
    add_test(NAME pursuit_tests COMMAND gci_tests)
endif()

# ─────────────────────────────────────────────────────────────
#  Install: Lua-Dateien in Ausgabe kopieren
# ─────────────────────────────────────────────────────────────
configure_file(lua/Export.lua ${CMAKE_BINARY_DIR}/Export.lua COPYONLY)
configure_file(lua/gci_bridge.lua ${CMAKE_BINARY_DIR}/gci_bridge.lua COPYONLY)
configure_file(lua/test_mission.lua ${CMAKE_BINARY_DIR}/test_mission.lua COPYONLY)

message(STATUS "")
message(STATUS "═══════════════════════════════════════")
message(STATUS "  GCI POC Build Configuration")
message(STATUS "  Server : ${BUILD_SERVER}")
message(STATUS "  Tests  : ${BUILD_TESTS}")
message(STATUS "═══════════════════════════════════════")
