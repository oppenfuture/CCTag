include_directories(${gtest_SOURCE_DIR}/include)
include_directories(${CMAKE_SOURCE_DIR}/src)

set(test_sources
    TestCCTagApi.cpp
)

add_executable(CCTagTests ${test_sources})


if (USE_CUDA)
target_link_libraries(CCTagTests gtest_main 
                     CCTag CCTagCuda
                     ${CUDA_LIBRARIES}
                     ${OPTPP_LIBRARIES}
				     ${Ceres_LIBRARIES}
				     ${CUDA_CUDADEVRT_LIBRARY} )
else()
target_link_libraries(CCTagTests gtest_main 
                      CCTag CCTagCuda
                     ${OPTPP_LIBRARIES}
				     ${Ceres_LIBRARIES})

endif()
