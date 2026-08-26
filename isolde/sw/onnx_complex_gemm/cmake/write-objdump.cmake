if(NOT DEFINED OBJDUMP OR NOT DEFINED ELF OR NOT DEFINED OUTPUT)
  message(FATAL_ERROR "OBJDUMP, ELF and OUTPUT are required")
endif()

execute_process(
  COMMAND "${OBJDUMP}" -fhSD -M no-aliases -M numeric "${ELF}"
  OUTPUT_FILE "${OUTPUT}"
  ERROR_VARIABLE objdump_error
  RESULT_VARIABLE objdump_result)

if(NOT objdump_result EQUAL 0)
  message(FATAL_ERROR "llvm-objdump failed: ${objdump_error}")
endif()

