cmake_minimum_required(VERSION 3.21)
project(libfp LANGUAGES C CXX)

include(CMakeDependentOption)

option(FP_ENABLE_DOCS "Weather or not the documentation should be built." OFF)
option(FP_ENABLE_TESTS "Weather or not Unit Tests should be built." ${PROJECT_IS_TOP_LEVEL})
cmake_dependent_option(FP_ENABLE_BENCHMARKING "Weather benchmarking should be enabled for the tests." ${PROJECT_IS_TOP_LEVEL} FP_ENABLE_TESTS OFF)
cmake_dependent_option(FP_ENABLE_PROFILING "Weather profiling should be enabled for the tests." ${PROJECT_IS_TOP_LEVEL} FP_ENABLE_TESTS OFF)
option(FP_FETCH_EXTERNAL_CPPSTL "Weather or not a minimal version of the C++ Standard Template Library should be fetched (Useful for embedded targets)" OFF)

# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address -Wall")
# set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fsanitize=address -Wall")

add_library(libfp INTERFACE)
add_library(libfp::fp ALIAS libfp)
target_include_directories(libfp INTERFACE include)

if(${FP_FETCH_EXTERNAL_CPPSTL})
	include(FetchContent)
	FetchContent_Declare(cppstl GIT_REPOSITORY https://github.com/modm-io/avr-libstdcpp.git)
	FetchContent_MakeAvailable(cppstl)

	file(GLOB libfp_external_libstl_sources "${cppstl_SOURCE_DIR}/src/*.cc")
	add_library(libfp_external_libstl ${libfp_external_libstl_sources})
	target_include_directories(libfp_external_libstl PUBLIC ${cppstl_SOURCE_DIR}/include)
	if(NOT MSVC)
		target_compile_options(libfp_external_libstl PUBLIC -fno-use-cxa-atexit)
	endif()

	target_link_libraries(libfp INTERFACE libfp_external_libstl)
	target_compile_definitions(libfp INTERFACE FP_CONSTEXPR=)
endif()

if(${FP_ENABLE_TESTS})
	include(FetchContent) # once in the project to include the module
	# FetchContent_Declare(fetch_cmake_scripts GIT_REPOSITORY https://github.com/StableCoder/cmake-scripts GIT_TAG origin/main GIT_SHALLOW true)
	# FetchContent_MakeAvailable(fetch_cmake_scripts)

	# include(${fetch_cmake_scripts_SOURCE_DIR}/tools.cmake)
	# cppcheck()

	# include(${fetch_cmake_scripts_SOURCE_DIR}/code-coverage.cmake)
	# add_code_coverage()

	# include(${fetch_cmake_scripts_SOURCE_DIR}/sanitizers.cmake)
	# add_sanitizer_support(address leak)

	enable_testing()
	if(TARGET doctest)
	else()
		FetchContent_Declare(fetch_doctest GIT_REPOSITORY https://github.com/doctest/doctest.git GIT_SHALLOW true)
		FetchContent_MakeAvailable(fetch_doctest)
	endif()

	if("${CMAKE_CXX_COMPILER_ID}" STREQUAL "MSVC")
		add_executable(tst-libfp tests/fp.tests.cpp tests/fp.tests.cpp-api.cpp)
	else()
		if(${FP_FETCH_EXTERNAL_CPPSTL})
			add_executable(tst-libfp tests/compiles.c)
		else()
			add_executable(tst-libfp tests/compiles.c tests/fp.tests.cpp tests/fp.tests.cpp-api.cpp)
		endif()
	endif()
	target_link_libraries(tst-libfp PUBLIC doctest libfp)
	set_property(TARGET tst-libfp PROPERTY CXX_STANDARD 23)
	set_property(TARGET tst-libfp PROPERTY C_STANDARD 23)
	# target_code_coverage(tst-libfp)

	if(${FP_ENABLE_BENCHMARKING})
		if(TARGET nanobench)
		else()
			FetchContent_Declare(fetch_nanobench GIT_REPOSITORY https://github.com/martinus/nanobench.git GIT_SHALLOW true)
			FetchContent_MakeAvailable(fetch_nanobench)
		endif()

		target_link_libraries(tst-libfp PUBLIC nanobench)
		target_compile_definitions(tst-libfp PUBLIC FP_ENABLE_BENCHMARKING)
	endif()

	if(${FP_ENABLE_PROFILING})
		option(BUILD_TRACY_PROFILER "Weather or not to build the server needed to view trace results." OFF)

		if(TARGET TracyClient)
		else()
			FetchContent_Declare(fetch_tracy GIT_REPOSITORY https://github.com/wolfpld/tracy GIT_SHALLOW true)
			FetchContent_MakeAvailable(fetch_tracy)
		endif()

		target_link_libraries(tst-libfp PUBLIC TracyClient)
		target_compile_definitions(tst-libfp PUBLIC FP_ENABLE_PROFILING)

		if(${BUILD_TRACY_PROFILER})
			# set(LEGACY ON CACHE BOOL "Instead of Wayland, use the legacy X11 backend on Linux")
			add_subdirectory(${fetch_tracy_SOURCE_DIR}/profiler/)
		endif()
	endif()
endif()

if(FP_ENABLE_DOCS)
	find_package(Doxygen)
	set(Sphinx_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
	find_package(Sphinx REQUIRED breathe)

	set(DOXYGEN_GENERATE_HTML NO)
	set(DOXYGEN_GENERATE_XML YES)
	configure_file(Doxyfile Doxyfile.fp_doxygen)
	doxygen_add_docs(fp_doxygen CONFIG_FILE ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile.fp_doxygen)

	sphinx_add_docs(
		fp_sphinx
		BREATHE_PROJECTS fp_doxygen
		BUILDER html
		SOURCE_DIRECTORY docs)
endif()
