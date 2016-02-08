
#include "gtest/gtest.h"
#include "cctag/CCTag.hpp"

using namespace cctag;


// Silly test to demonstrate how to use gtest macros
TEST(CCTagConstructor, ParametersIDIsZero) {

    // Construct a default CCTag object
    CCTag dummyCCTag;

    // Double check the id is equal to zero
    ASSERT_EQ(dummyCCTag.id(), 0);
}


