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
if(MSVC)
    target_compile_options(gci_core PRIVATE
        /MT
        /O2
        /W3
    )
endif()
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
    if(NOT LUA51_LIB OR NOT LUA51_INCLUDE)
        message(WARNING
            "  BUILD_DLL=ON aber LUA51_LIB oder LUA51_INCLUDE nicht gesetzt.\n"
            "  Setze: -DLUA51_LIB=<pfad/lua51.lib> -DLUA51_INCLUDE=<pfad/include>")
        set(BUILD_DLL OFF)
    else()
        # Lua 5.1 als imported target — analog zu HoundTTS
        add_library(lua51_imported SHARED IMPORTED)
        set_target_properties(lua51_imported PROPERTIES
            IMPORTED_LOCATION "${LUA51_LIB}/../lua51.dll"
            IMPORTED_IMPLIB   "${LUA51_LIB}"
            INTERFACE_INCLUDE_DIRECTORIES "${LUA51_INCLUDE}"
        )

        add_library(gci_dll SHARED
            src/gci_lua.c
        )
        set_target_properties(gci_dll PROPERTIES
            OUTPUT_NAME         "gci_core"
            PREFIX              ""
            ARCHIVE_OUTPUT_NAME "gci_dll"
        )
        target_include_directories(gci_dll PRIVATE
            include
            ${LUA51_INCLUDE}
        )
        target_compile_definitions(gci_dll PRIVATE
            LUA_BUILD_AS_DLL
        )
        target_link_libraries(gci_dll PRIVATE
            gci_core
            lua51_imported
        )
        if(MSVC)
            target_compile_options(gci_dll PRIVATE
                /MT
                /O2
                /W3
            )
            target_link_options(gci_dll PRIVATE
                /NODEFAULTLIB:MSVCRT
                /NODEFAULTLIB:MSVCRTD
            )
        endif()
        if(NOT MSVC)
            target_link_libraries(gci_dll PRIVATE m)
        endif()

        add_custom_command(TARGET gci_dll POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy
                $<TARGET_FILE:gci_dll>
                ${CMAKE_BINARY_DIR}/gci_core.dll
            COMMENT "gci_core.dll → ${CMAKE_BINARY_DIR}"
        )

        message(STATUS "  Lua 5.1  : ${LUA51_LIB}")
        message(STATUS "  DLL      : ON")
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
configure_file(lua/Export.lua        ${CMAKE_BINARY_DIR}/Export.lua        COPYONLY)
configure_file(lua/gci_bridge.lua    ${CMAKE_BINARY_DIR}/gci_bridge.lua    COPYONLY)
configure_file(lua/gci_mission.lua   ${CMAKE_BINARY_DIR}/gci_mission.lua   COPYONLY)
configure_file(lua/test_mission.lua  ${CMAKE_BINARY_DIR}/test_mission.lua  COPYONLY)

message(STATUS "========================================")
message(STATUS "  Compiler : ${CMAKE_C_COMPILER_ID}")
message(STATUS "  Server   : ${BUILD_SERVER}")
message(STATUS "  DLL      : ${BUILD_DLL}")
message(STATUS "  Tests    : ${BUILD_TESTS}")
message(STATUS "========================================")
