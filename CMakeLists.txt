cmake_minimum_required(VERSION 3.20)
project(rdp-retina VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREERDP REQUIRED IMPORTED_TARGET freerdp-client3>=3.29 freerdp3 winpr3)

# Laufzeitpfad auf die gefundenen Bibliotheken, damit ein eigener FreeRDP-Build
# ohne LD_LIBRARY_PATH startet.
set(CMAKE_BUILD_RPATH ${FREERDP_LIBRARY_DIRS})

set(RR_WARNINGS -Wall -Wextra -Wno-unused-parameter)

# ---- Kern: portabel, ohne Oberfläche ---------------------------------------------------
add_library(rr_core STATIC
	core/rr_context.c
	core/rr_settings.c
	core/rr_gfx.c
	core/rr_disp.c
	core/rr_rail.c
	core/rr_input.c)
target_include_directories(rr_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/core)
target_link_libraries(rr_core PUBLIC PkgConfig::FREERDP)
target_compile_options(rr_core PRIVATE ${RR_WARNINGS})

# ---- Prüf-Client ohne Fenster ----------------------------------------------------------
add_executable(rdp-probe probe/rr_probe.c)
target_link_libraries(rdp-probe PRIVATE rr_core)
target_compile_options(rdp-probe PRIVATE ${RR_WARNINGS})
