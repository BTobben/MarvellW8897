#ifndef _MARVELL_W8897_TRANSPORT_HPP
#define _MARVELL_W8897_TRANSPORT_HPP

#include "MarvellW8897PciBars.hpp"

enum MarvellW8897TransportQuirk : UInt32 {
    kMarvellW8897TransportQuirkTxWritePointerReadback = (1U << 0),
    kMarvellW8897TransportQuirkIgnoreBtcoexEvents = (1U << 1),
};

enum class MarvellW8897TransportProfileKind : UInt32 {
    None = 0,
    MwifiexPcie8897,
};

struct MarvellW8897TransportPcieProfile {
    MarvellW8897TransportProfileKind kind { MarvellW8897TransportProfileKind::None };
    UInt32                           firmwareStatusReg { 0 };
    UInt32                           driverReadyReg { 0 };
    UInt32                           txReadPointerReg { 0 };
    UInt32                           txWritePointerReg { 0 };
    UInt32                           rxReadPointerReg { 0 };
    UInt32                           rxWritePointerReg { 0 };
    UInt32                           eventReadPointerReg { 0 };
    UInt32                           eventWritePointerReg { 0 };
    UInt32                           txRingMask { 0 };
    UInt32                           txRingWrapMask { 0 };
    UInt32                           rxRingMask { 0 };
    UInt32                           rxRingWrapMask { 0 };
    UInt32                           quirkFlags { 0 };
    const char*                      defaultFirmwareName { nullptr };
};

struct MarvellW8897TransportState {
    UInt32 txRingWritePtr { 0 };
    UInt32 txRingReadPtr { 0 };
    UInt32 rxRingWritePtr { 0 };
    UInt32 rxRingReadPtr { 0 };
    UInt32 irqStatus { 0 };
    UInt32 firmwareReady { 0 };
    UInt32 lastEventId { 0 };
    UInt32 btcoexEventsIgnored { 0 };
    MarvellW8897TransportPcieProfile pcieProfile {};
};

namespace MarvellW8897Transport {

void reset(MarvellW8897TransportState& state);
bool configurePcieProfile(MarvellW8897TransportState& state, UInt16 vendorId, UInt16 deviceId);
const MarvellW8897TransportPcieProfile* getPcieProfile(const MarvellW8897TransportState& state);
bool readReg32FromBar(const MarvellW8897PciBarState& pciBars,
                      UInt32 barIndex,
                      UInt32 offset,
                      UInt32& valueOut);
bool writeReg32ToBar(const MarvellW8897PciBarState& pciBars,
                     UInt32 barIndex,
                     UInt32 offset,
                     UInt32 value);
bool writeReg32ToBarWithFlush(const MarvellW8897PciBarState& pciBars,
                              MarvellW8897TransportState& transportState,
                              UInt32 barIndex,
                              UInt32 offset,
                              UInt32 value,
                              UInt32& readBack);
bool getTransportState(const MarvellW8897TransportState& state,
                       UInt64 outState[MarvellW8897Regs::kTransportStateCount]);

} // namespace MarvellW8897Transport

#endif
