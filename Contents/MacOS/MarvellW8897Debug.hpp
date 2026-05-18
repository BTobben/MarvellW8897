#ifndef _MARVELL_W8897_DEBUG_HPP
#define _MARVELL_W8897_DEBUG_HPP

#include "MarvellW8897Regs.hpp"

namespace MarvellW8897Debug {

bool getDebugAbiInfo(UInt64 outInfo[MarvellW8897Regs::kDebugAbiInfoCount]);

} // namespace MarvellW8897Debug

#endif
