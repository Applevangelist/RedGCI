cmake_minimum_required(VERSION 3.16)
project(gci_poc C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(BUILD_TESTS     "Build unit tests"         ON)
option(BUILD_SERVER    "Build UDP server (EXE)"   ON)
option(BUILD_DLL       "Build Lua DLL (Phase 2)"  ON)

if(MSVC)
    add_compile_options(/O2 /W3)
    add_compile_definitions(
        _CRT_SECURE_NO_WARNINGS
        _WINSOCK_DEPRECATED_NO_WARNINGS
    )
else()
    add_compile_options(-O2 -Wall -Wextra)
endif()

# ── Kern-Bibliothek (statisch) ────────────────────────────────
add_library(gci_core STATIC
    src/pursuit_solver.c
    src/intercept_fsm.c
    src/merge_controller.c
    src/message_handler.c
)
target_include_directories(gci_core PUBLIC include)
if(NOT MSVC)
    target_link_libraries(gci_core m)
endif()

# ── UDP Server (EXE) ──────────────────────────────────────────
if(BUILD_SERVER)
    add_executable(gci_server src/gci_server.c)
    target_link_libraries(gci_server gci_core)
    if(WIN32)
        target_link_libraries(gci_server ws2_32)
    endif()
endif()

# ── Lua DLL (Phase 2) ─────────────────────────────────────────
if(BUILD_DLL)
    # Lua 5.1 suchen — DCS-Pfad als Hint
    find_library(LUA51_LIB
        NAMES lua51 lua5.1 lua-5.1
        HINTS
            "$ENV{DCS_SDK}/lua51"
            "C:/Program Files/Eagle Dynamics/DCS World/bin"
            "C:/Program Files (x86)/Eagle Dynamics/DCS World/bin"
            ${CMAKE_SOURCE_DIR}/lua51
    )
    find_path(LUA51_INCLUDE
        NAMES lua.h
        HINTS
            "$ENV{DCS_SDK}/lua51/include"
            ${CMAKE_SOURCE_DIR}/lua51/include
            ${CMAKE_SOURCE_DIR}/third_party/lua51
    )

    if(LUA51_LIB AND LUA51_INCLUDE)
        add_library(gci_dll SHARED
            src/gci_lua.c
        )
        set_target_properties(gci_dll PROPERTIES
            OUTPUT_NAME "gci_core"      # → gci_core.dll
            PREFIX      ""              # kein lib-Prefix auf Linux
        )
        target_include_directories(gci_dll PRIVATE
            include
            ${LUA51_INCLUDE}
        )
        target_link_libraries(gci_dll
            gci_core
            ${LUA51_LIB}
        )
        if(NOT MSVC)
            target_link_libraries(gci_dll m)
        endif()

        # DLL nach Build-Verzeichnis kopieren
        add_custom_command(TARGET gci_dll POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy
                $<TARGET_FILE:gci_dll>
                ${CMAKE_BINARY_DIR}/gci_core.dll
            COMMENT "gci_core.dll → ${CMAKE_BINARY_DIR}"
        )

        message(STATUS "  Lua 5.1  : ${LUA51_LIB}")
        message(STATUS "  DLL      : ON")
    else()
        message(WARNING
            "  Lua 5.1 nicht gefunden — BUILD_DLL deaktiviert.\n"
            "  Lösung A: lua51.lib + lua.h nach ${CMAKE_SOURCE_DIR}/lua51/\n"
            "  Lösung B: cmake -DLUA51_LIB=<pfad> -DLUA51_INCLUDE=<pfad>")
        set(BUILD_DLL OFF)
    endif()
endif()

# ── Tests ─────────────────────────────────────────────────────
if(BUILD_TESTS)
    enable_testing()
    add_executable(gci_tests test/test_pursuit.c)
    target_link_libraries(gci_tests gci_core)
    if(NOT MSVC)
        target_link_libraries(gci_tests m)
    endif()
    add_test(NAME pursuit_tests COMMAND gci_tests)
endif()

# ── Lua-Dateien ins Build-Verzeichnis ─────────────────────────
configure_file(lua/Export.lua       ${CMAKE_BINARY_DIR}/Export.lua       COPYONLY)
configure_file(lua/gci_bridge.lua   ${CMAKE_BINARY_DIR}/gci_bridge.lua   COPYONLY)
configure_file(lua/test_mission.lua ${CMAKE_BINARY_DIR}/test_mission.lua COPYONLY)

message(STATUS "========================================")
message(STATUS "  Compiler : ${CMAKE_C_COMPILER_ID}")
message(STATUS "  Server   : ${BUILD_SERVER}")
message(STATUS "  DLL      : ${BUILD_DLL}")
message(STATUS "  Tests    : ${BUILD_TESTS}")
message(STATUS "========================================")
