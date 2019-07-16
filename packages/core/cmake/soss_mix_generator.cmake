# Copyright 2019 Open Source Robotics Foundation, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# copied from soss/cpp/core/cmake/soss_mix_generator.cmake

include(CMakeParseArguments)
include(GNUInstallDirs)

#################################################
# soss_mix_generator(
#   IDL_TYPE idl_type
#   SCRIPT
#     INTERPRETER <python2|python3|other>
#     FIND find_script
#     GENERATE
#   PACKAGES packages...
#   MIDDLEWARES [ros2|websocket|hl7]...
#   [QUIET]
#   [REQUIRED]
# )
#
# Generate a soss middleware interface extension for a set of IDL packages.
#
# ROS2 packages will often contain message and service specifications in the
# form of rosidl files (.msg and .srv). This cmake utility will convert the
# messages and services into soss middleware interface extension libraries.
# That will allow soss to pass those message and service types between two
# different middlewares.
#
# The PACKAGES argument specifies the packages whose message and service
# specifications you want to convert (you can specify any number of packages).
# If any of the messages or services in one of the requested packages depends on
# messages in another package, then those package dependencies will be searched
# for to see if they've already been generated. If any of the dependencies have
# not been generated already, then they will be generated by this function call.
#
# The MIDDLEWARES argument specifies which middlewares to create extensions for.
#
# Use the QUIET option to suppress status updates.
#
# Use the REQUIRED option to have a fatal error if anything has prevented the
# mix libraries from being generated. If REQUIRED is not specified, then this
# function will instead print warnings and proceed as much as possible whenever
# an error is encountered.
function(soss_mix_generator)

  cmake_parse_arguments(
    _ARG # prefix
    "QUIET;REQUIRED" # options
    "IDL_TYPE" # one-value arguments
    "PACKAGES;MIDDLEWARES;SCRIPT" # multi-value arguments
    ${ARGN}
  )

  cmake_parse_arguments(
    _SCRIPT
    "" # options
    "INTERPRETER;FIND;GENERATE" # one-value arguments
    "" # multi-value arguments
    ${ARGN}
  )

  if(_ARG_UNPARSED_ARGUMENTS)
    message(AUTHOR_WARNING
      "Unknown arguments passed to "
      "soss_mix_generator:"
      "${_ARG_UNPARSED_ARGUMENTS}"
    )
  endif()

  set(_problem_output_type "WARNING")
  if(_ARG_REQUIRED)
    set(_problem_output_type "FATAL_ERROR")
  endif()

  set(_found_middleware_mixes)
  set(_string_of_middlewares "")
  foreach(middleware ${_ARG_MIDDLEWARES})

    set(_mix_pkg_name soss-${_ARG_IDL_TYPE}-${middleware}-mix)
    find_package(${_mix_pkg_name} QUIET)
    if(${_mix_pkg_name}_FOUND)
      list(APPEND _found_middleware_mixes "${middleware}")
    else()
      message(${_problem_output_type}
        "Could not find the ${_ARG_IDL_TYPE} extension for [${middleware}]! "
        "You need to install the package [${_mix_pkg_name}] if such a "
        "package exists. We will skip generating a soss mix library for that "
        "middleware."
      )
    endif()

  endforeach()

  #########################
  # Initialize these lists
  set(_queued_packages)
  set(_queued_dependencies)
  set(_recursive_dependencies)

  foreach(middleware ${_found_middleware_mixes})
    set(_queued_${middleware}_packages)
  endforeach()

  #########################
  # Find the recursive dependencies of each requested package
  foreach(requested_pkg ${_ARG_PACKAGES})

    find_package(${requested_pkg} QUIET)
    if(${requested_pkg}_FOUND)

      list(APPEND _queued_dependencies ${requested_pkg})
      _soss_mix_find_package_info(
        SCRIPT
          INTERPRETER ${_SCRIPT_INTERPRETER}
          FIND ${_SCRIPT_FIND}
        PACKAGE           ${requested_pkg}
        OUTPUT_PKG_DEP   _${requested_pkg}_recursive_dependencies
        OUTPUT_MSG_FILE  _${requested_pkg}_msg_files
        OUTPUT_SRV_FILE  _${requested_pkg}_srv_files
        OUTPUT_FILE_DEP  _${requested_pkg}_file_dependencies
      )

      foreach(dependency ${_${requested_pkg}_recursive_dependencies})
        list(APPEND _recursive_dependencies ${dependency})
        list(APPEND _dependents_of_${dependency} ${requested_pkg})
        set(_dependents_of_${dependency}_string "${_dependents_of_${dependency}_string} [${requested_pkg}]")
      endforeach()

      # Add the dependency to the list of packages whose mix soss libraries we
      # should look for
      list(APPEND _queued_packages ${requested_pkg})
      set(_dependents_of_${requested_pkg}_string " [the user]")

    else()

      message(${_problem_output_type}
        "Could not find a ${_ARG_IDL_TYPE} package named [${requested_pkg}]! "
        "You need to install that package in order to generate soss mix "
        "libraries for its message and service specifications."
      )

    endif()

  endforeach()

  if(_recursive_dependencies)
    list(REMOVE_DUPLICATES _recursive_dependencies)
  endif()

  #########################
  # Look for the message package for each dependency (if the build environment
  # is sanitary, this should always work, because we've already confirmed that
  # the top-level message package was available; a configuration error here most
  # likely means that the user's build environment is borked somehow)
  foreach(dependency ${_recursive_dependencies})
    find_package(${dependency} QUIET)
    if(NOT ${dependency}_FOUND)

      message(${_problem_output_type}
        "Could not find the dependency [${dependency}]. "
        "Its dependent packages${_dependents_of_${dependency}_string} will be "
        "skipped."
      )

      foreach(dependent ${_dependents_of_${dependency}})
        list(REMOVE_ITEM _queued_dependencies ${dependent})
        list(REMOVE_ITEM _recursive_dependencies ${dependent})
      endforeach()

      continue()

    endif()

    # Add this package to the list of packages to be considered for building
    list(APPEND _queued_packages ${dependency})

    # If this package is going to be built, we will also need its dependency
    # info, so add it to a list of packages on which we will call
    # _soss_mix_find_package_info
    list(APPEND _queued_dependencies ${dependency})

  endforeach()

  if(_queued_packages)
    list(REMOVE_DUPLICATES _queued_packages)
  endif()

  #########################
  # For each package that has been queued, we will check for an already existing
  # mix extension for each requested+available middleware.
  foreach(package ${_queued_packages})

    foreach(middleware ${_found_middleware_mixes})
      set(_package_mix_pkg_name soss-${_ARG_IDL_TYPE}-${middleware}-${package}-mix)
      find_package(${_package_mix_pkg_name} QUIET)
      if(${_package_mix_pkg_name}_FOUND)

        if(NOT _ARG_QUIET)
          message(STATUS
            "Found [${middleware}] mix for package [${package}] required "
            "by${_dependents_of_${package}_string}."
          )
        endif()

      else()

        if(NOT _ARG_QUIET)
          message(STATUS
            "Could not find [${middleware}] mix for package "
            "[${package}] required by${_dependents_of_${package}_string}"
            ". The [${middleware}] mix for [${package}] will be "
            "automatically generated."
          )
        endif()

        list(APPEND _queued_${middleware}_packages ${package})

      endif()
    endforeach()

  endforeach()

  if(_queued_dependencies)
    list(REMOVE_DUPLICATES _queued_dependencies)
  endif()

  #########################
  # For each of the automatically inferred dependencies, find its package info,
  # because it will be needed if we have to build it.
  foreach(dependency ${_queued_dependencies})
    _soss_mix_find_package_info(
      SCRIPT
        INTERPRETER ${_SCRIPT_INTERPRETER}
        FIND ${_SCRIPT_FIND}
      PACKAGE           ${dependency}
      OUTPUT_PKG_DEP   _${dependency}_dependencies
      OUTPUT_MSG_FILE  _${dependency}_msg_files
      OUTPUT_SRV_FILE  _${dependency}_srv_files
      OUTPUT_FILE_DEP  _${dependency}_file_dependencies
    )
  endforeach()
  #########################
  # Generate files and configure targets for every required package that didn't
  # already have a mix made and installed.
  foreach(middleware ${_found_middleware_mixes})
    foreach(package ${_queued_${middleware}_packages})
      _soss_configure_mix_package(
        IDL_TYPE      ${_ARG_IDL_TYPE}
        SCRIPT
          INTERPRETER ${_SCRIPT_INTERPRETER}
          GENERATE    ${_SCRIPT_GENERATE}
        MIDDLEWARE    ${middleware}
        PACKAGE       ${package}
        DEPENDENCIES  ${_${package}_dependencies}
        MSG_FILES     ${_${package}_msg_files}
        SRV_FILES     ${_${package}_srv_files}
        FILE_DEPS     ${_${package}_file_dependencies}
      )

    endforeach()
  endforeach()

endfunction()

#################################################
# _soss_configure_mix_package(
#   IDL_TYPE      <idl_type>
#   SCRIPT
#     INTERPRETER <interpreter>
#     GENERATE    <generate_script>
#   MIDDLEWARE    <middleware>
#   PACKAGE       <package>
#   DEPENDENCIES  [dependencies...]
#   MSG_FILES     [msg_files...]
#   SRV_FILES     [srv_files...]
#   FILE_DEPS     [file_dependencies...]
# )
function(_soss_configure_mix_package)

  cmake_parse_arguments(
    _ARG # prefix
    "" # options
    "IDL_TYPE;MIDDLEWARE;PACKAGE" # one-value arguments
    "SCRIPT;DEPENDENCIES;MSG_FILES;SRV_FILES;FILE_DEPS" # multi-value arguments
    ${ARGN}
  )

  cmake_parse_arguments(
    _SCRIPT # prefix
    "" # options
    "INTERPRETER;GENERATE" # one-value arguments
    "" # multi-value arguments
    ${_ARG_SCRIPT}
  )

  foreach(required_arg _ARG_MIDDLEWARE _ARG_PACKAGE)
    if(NOT ${required_arg})
      message(FATAL_ERROR
        "Missing ${required_arg} argument, which is required! This indicates a "
        "bug in the soss cmake module, please report this!"
      )
    endif()
  endforeach()

  set(middleware ${_ARG_MIDDLEWARE})
  set(package ${_ARG_PACKAGE})
  set(mix_target soss-${_ARG_IDL_TYPE}-${middleware}-${package}-mix)
  if(TARGET ${mix_target})
    # This mix library has already been configured, so we can skip it
    return()
  endif()

  if(NOT _ARG_QUIET)
    message(STATUS
      "Configuring [${package}] mix library for [${middleware}] "
      "middleware"
    )
  endif()

  include("${SOSS_${_ARG_IDL_TYPE}_${middleware}_EXTENSION}")

  if(_${middleware}_${package}_mix_cpp_files)
    # If the middleware extension provided these variables explicitly, use them
    # as-is.
  elseif(_${middleware}_${package}_use_templates)
    # If the middleware provided cpp and/or hpp templates instead of explicit
    # source/header files, we can use those to generate the source files.
    _soss_mix_generate_source_files(
      IDL_TYPE ${_ARG_IDL_TYPE}
      SCRIPT
        INTERPRETER ${_SCRIPT_INTERPRETER}
        GENERATE ${_SCRIPT_GENERATE}
      MIDDLEWARE ${middleware}
      PACKAGE ${package}
      MESSAGE
        IDL ${_ARG_MSG_FILES}
        CPP ${_${middleware}_${package}_msg_cpp}
        HPP ${_${middleware}_${package}_msg_hpp}
      SERVICE
        IDL ${_ARG_SRV_FILES}
        CPP ${_${middleware}_${package}_srv_cpp}
        HPP ${_${middleware}_${package}_srv_hpp}
      FILE_DEPS ${_ARG_FILE_DEPS}
      OUTPUT
        CPP_FILES _${middleware}_${package}_mix_cpp_files
        INCLUDE_DIR _${middleware}_${package}_mix_include_dir
    )
  else()

    message(${_problem_output_type}
      "The soss-${_ARG_IDL_TYPE}-${middleware}.cmake extension is broken or incompatible "
      "with this version of the soss-${_ARG_IDL_TYPE} generator!"
    )

  endif()

  _soss_mix_get_filenames_list(
    _${package}_msg_types
    ${_ARG_MSG_FILES}
  )

  _soss_mix_get_filenames_list(
    _${package}_srv_types
    ${_ARG_SRV_FILES}
  )

  add_library(${mix_target} SHARED ${_${middleware}_${package}_mix_cpp_files})

  set(_soss_mix_dependencies)
  set(_pkg_library_dependencies ${${package}_LIBRARIES})
  set(_pkg_include_dirs ${${package}_INCLUDE_DIRS})
  foreach(dep ${_ARG_DEPENDENCIES})
    list(APPEND _soss_mix_dependencies soss-${_ARG_IDL_TYPE}-${middleware}-${dep}-mix)
    list(APPEND _pkg_library_dependencies ${${dep}_LIBRARIES})
    list(APPEND _pkg_include_dirs ${${dep}_INCLUDE_DIRS})
  endforeach()

  target_link_libraries(${mix_target}
    PUBLIC
      soss::core
      soss::${middleware}
      ${_pkg_library_dependencies}
      ${_soss_mix_dependencies}
  )

  target_include_directories(${mix_target}
    PUBLIC
      $<BUILD_INTERFACE:${_${middleware}_${package}_mix_include_dir}>
      $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
      ${_pkg_include_dirs}
  )

  set(library_build_dir "${CMAKE_BINARY_DIR}/soss/${_ARG_IDL_TYPE}/${middleware}/lib")

  set_target_properties(${mix_target} PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${library_build_dir}
  )

  install(
    TARGETS ${mix_target}
    EXPORT  ${mix_target}
    DESTINATION ${CMAKE_INSTALL_LIBDIR}
    COMPONENT soss-${_ARG_IDL_TYPE}-mix
  )

  set(config_install_dir ${CMAKE_INSTALL_LIBDIR}/cmake/${mix_target})

  install(
    EXPORT ${mix_target}
    DESTINATION ${config_install_dir}
    FILE ${mix_target}-target.cmake
    COMPONENT soss-${_ARG_IDL_TYPE}-mix
  )

  set(config_output ${CMAKE_BINARY_DIR}/soss/${_ARG_IDL_TYPE}/config/${mix_target}Config.cmake)
  configure_file(
    "${SOSS_IDL_PKG_MIX_CONFIG_TEMPLATE}"
    ${config_output}
    @ONLY
  )

  install(
    FILES ${config_output}
    DESTINATION ${config_install_dir}
    COMPONENT soss-${_ARG_IDL_TYPE}-mix
  )

  if(_${middleware}_${package}_mix_include_dir)
    if(EXISTS ${_${middleware}_${package}_mix_include_dir})
      install(
        DIRECTORY ${_${middleware}_${package}_mix_include_dir}/
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
      )
    endif()
  endif()

  set(plugin_library_extension $<IF:$<PLATFORM_ID:Windows>,"dll","dl">)

  set(plugin_library_target ${mix_target})
  set(plugin_library_directory ../../../..)
  set(_plugin_library_gen_template "${CMAKE_BINARY_DIR}/soss/${_ARG_IDL_TYPE}/${middleware}/${package}.mix.gen")
  configure_file(
    ${SOSS_TEMPLATE_DIR}/plugin_library.mix.in
    ${_plugin_library_gen_template}
    @ONLY
  )

  set(mix_build_dir "${library_build_dir}/soss")
  set(mix_msg_build_dir "${mix_build_dir}/${middleware}/msg/${package}")
  foreach(msg_type ${_${package}_msg_types})
    file(GENERATE
      OUTPUT ${mix_msg_build_dir}/${msg_type}.mix
      INPUT ${_plugin_library_gen_template}
    )
  endforeach()

  set(mix_srv_build_dir "${mix_build_dir}/${middleware}/srv/${package}")
  foreach(srv_type ${_${package}_srv_types})
    file(GENERATE
      OUTPUT ${mix_srv_build_dir}/${srv_type}.mix
      INPUT ${_plugin_library_gen_template}
    )
  endforeach()

  install(
    DIRECTORY ${mix_build_dir}
    DESTINATION ${CMAKE_INSTALL_LIBDIR}
    COMPONENT soss-${_ARG_IDL_TYPE}-mix
  )

endfunction()

function(_soss_mix_get_filenames_list var)

  set(output)
  foreach(file ${ARGN})
    get_filename_component(filename ${file} NAME_WE)
    list(APPEND output "${filename}")
  endforeach()

  set(${var} ${output} PARENT_SCOPE)

endfunction()

#################################################
# _soss_mix_generate_source_files(
#   IDL_TYPE <idl_type>
#   SCRIPT
#     INTERPRETER <python2|python3|other>
#     GENERATE <generation_script>
#   MIDDLEWARE <middleware>
#   PACKAGE <package>
#   MESSAGE
#     IDL <idl_msg_files>
#     CPP <cpp_translation_unit_template_files_for_messages>
#     HPP <cpp_header_template_files_for_messages>
#   SERVICE
#     IDL <idl_srv_files>
#     CPP <cpp_translation_unit_template_files_for_services>
#     HPP <cpp_header_template_files_for_services>
#   FILE_DEPS [files_dependencies...]
#   OUTPUT
#     CPP_FILES <output_cpp_files_variable>
#     INCLUDE_DIR <output_include_directory_variable>
# )
function(_soss_mix_generate_source_files)

  cmake_parse_arguments(
    _ARG # prefix
    "" # options
    "IDL_TYPE;PACKAGE" # one-value arguments
    "SCRIPT;MESSAGE;SERVICE;FILE_DEPS;OUTPUT" # multi-value arguments
    ${ARGN}
  )

  cmake_parse_arguments(
    _SCRIPT # prefix
    "" # options
    "INTERPRETER;GENERATE" # one-value arguments
    "" # multi-value arguments
    ${_ARG_SCRIPT}
  )

  cmake_parse_arguments(
    _ARG_MSG # prefix
    "" # options
    "" # one-value arguments
    "IDL;CPP;HPP" # multi-value arguments
    "${_ARG_MESSAGE}"
  )

  cmake_parse_arguments(
    _ARG_SRV # prefix
    "" # options
    "" # one-value arguments
    "IDL;CPP;HPP" # multi-value arguments
    "${_ARG_SERVICE}"
  )

  cmake_parse_arguments(
    _ARG_OUTPUT
    "" # options
    "" # one-value arguments
    "CPP_FILES;INCLUDE_DIR" # multi-value arguments
    "${_ARG_OUTPUT}"
  )

  set(middleware ${_ARG_MIDDLEWARE})
  set(package ${_ARG_PACKAGE})

  set(output_src_dir "${PROJECT_BINARY_DIR}/soss/${_ARG_IDL_TYPE}/${middleware}/${package}/src")
  set(output_include_dir "${PROJECT_BINARY_DIR}/soss/${_ARG_IDL_TYPE}/${middleware}/${package}/include")

  # Generate files from message specifications
  execute_process(
    COMMAND
      ${_SCRIPT_INTERPRETER}
      ${_SCRIPT_GENERATE}
      --package       ${package}
      --source-dir    "${output_src_dir}"
      --header-dir    "${output_include_dir}/soss/${_ARG_IDL_TYPE}/${middleware}/${package}"
      --msg-idl-files ${_ARG_MSG_IDL}
      --msg-cpp-files ${_ARG_MSG_CPP}
      --msg-hpp-files ${_ARG_MSG_HPP}
      --srv-idl-files ${_ARG_SRV_IDL}
      --srv-cpp-files ${_ARG_SRV_CPP}
      --srv-hpp-files ${_ARG_SRV_HPP}
    OUTPUT_VARIABLE script_output
    ERROR_VARIABLE script_error
  )

  if(script_output)
    message(STATUS
      "Output from generating ${middleware} source files for ${package}:"
      "\n${script_output}"
    )
  endif()

  if(script_error)
    message(FATAL_ERROR
      "Critical failure when trying to generate ${middleware} source files for "
      "${package}:\n${script_error}"
    )
  endif()

  file(GLOB output_msg_cpp ${output_src_dir}/msg/*.cpp)
  file(GLOB output_srv_cpp ${output_src_dir}/srv/*.cpp)
  set(output_cpp ${output_msg_cpp} ${output_srv_cpp})

  set(${_ARG_OUTPUT_CPP_FILES} ${output_cpp} PARENT_SCOPE)
  set(${_ARG_OUTPUT_INCLUDE_DIR} ${output_include_dir} PARENT_SCOPE)

endfunction()

#################################################
# _soss_mix_find_package_info(
#   SCRIPT
#     INTERPRETER <python2|python3|other>
#     FIND find_script
#   PACKAGE          <package>
#   OUTPUT_PKG_DEP   <package_dependency_list_var>
#   OUTPUT_MSG_FILE  <package_message_list_var>
#   OUTPUT_SRV_FILE  <package_service_list_var>
#   OUTPUT_FILE_DEP  <file_dependency_list_var>
# )
function(_soss_mix_find_package_info)

  set(output_vars OUTPUT_PKG_DEP OUTPUT_MSG_FILE OUTPUT_SRV_FILE OUTPUT_FILE_DEP)
  set(args PACKAGE ${output_vars})
  cmake_parse_arguments(
    _ARG # prefix
    "" # options
    "${args}" # one-value arguments
    "SCRIPT" # multi-value arguments
    ${ARGN}
  )

  cmake_parse_arguments(
    _SCRIPT # prefix
    "" # options
    "INTERPRETER;FIND" # one-value arguments
    "" # multi-value arguments
    ${_ARG_SCRIPT}
  )

  foreach(required_arg ${args})
    if(NOT _ARG_${required_arg})
      message(FATAL_ERROR
        "Missing ${required_arg} argument, which is required! This indicates a "
        "bug in the soss cmake module, please report this!"
      )
    endif()
  endforeach()

  execute_process(
    COMMAND
      ${_SCRIPT_INTERPRETER}
      ${_SCRIPT_FIND}
      ${_ARG_PACKAGE}
    OUTPUT_VARIABLE script_output
    ERROR_VARIABLE  script_error
  )

  if(script_error)
    message(FATAL_ERROR
      "Critical failure when trying to parse the package information of "
      "${_ARG_PACKAGE}:\n${script_error}"
    )
  endif()

  list(LENGTH script_output script_output_len)
  list(LENGTH output_vars expected_len)
  if(NOT script_output_len EQUAL expected_len)
    message(FATAL_ERROR
      "Critical failure when trying to parse the package information of "
      "${_ARG_PACKAGE}: The python script output a list with "
      "${script_output_len} elements instead of ${expected_len}."
    )
  endif()

  list(GET script_output 0 OUTPUT_PKG_DEP)
  list(GET script_output 1 OUTPUT_MSG_FILE)
  list(GET script_output 2 OUTPUT_SRV_FILE)
  list(GET script_output 3 OUTPUT_FILE_DEP)

  foreach(output_var ${output_vars})
    # The original output is a semicolon-separated list of four hash-separated
    # lists. The four hash-separated lists were split apart above using
    # list(GET ...). Now we convert each of those hash-separated lists into
    # semicolon-separated lists so that cmake can recognize them correctly as
    # lists.
    string(REPLACE "#" ";" ${output_var} "${${output_var}}")

    # We pass the result up to the parent scope
    set(${_ARG_${output_var}} ${${output_var}} PARENT_SCOPE)
  endforeach()

endfunction()
