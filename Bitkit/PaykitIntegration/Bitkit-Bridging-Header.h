//
//  Bitkit-Bridging-Header.h
//  Bitkit
//
//  Bridging header for Paykit FFI integration
//

#ifndef Bitkit_Bridging_Header_h
#define Bitkit_Bridging_Header_h

// Import PaykitMobile FFI types
#include "paykit_mobileFFI.h"

// Import PubkyNoise FFI types
// The correct header is found via HEADER_SEARCH_PATHS which are conditionally
// set for device (ios-arm64) vs simulator (ios-arm64_x86_64-simulator)
#include "pubky_noiseFFI.h"

#endif /* Bitkit_Bridging_Header_h */

