#include "MarvellW8897Transport.hpp"
#include <libkern/OSByteOrder.h>

namespace {

constexpr UInt16 kVendorIdMarvell88W8897 = 0x11ab;
constexpr UInt16 kDeviceIdMarvell88W8897 = 0x2b38;
constexpr UInt32 kPcieScratch3Reg = 0x0C44;
constexpr UInt32 kPcieScratch10Reg = 0x0CE8;
constexpr UInt32 kPcieScratch11Reg = 0x0CEC;
constexpr UInt32 kPcieScratch12Reg = 0x0CF0;
constexpr UInt32 kPcieRdDataPtrQ0Q1 = 0xC08C;
constexpr UInt32 kPcieWrDataPtrQ0Q1 = 0xC05C;
constexpr UInt32 kPcie8897TxRingMask = 0x03FF0000;
constexpr UInt32 kPcie8897TxRingWrapMask = 0x07FF0000;
constexpr UInt32 kPcie8897RxRingMask = 0x000003FF;
constexpr UInt32 kPcie8897RxRingWrapMask = 0x000007FF;
constexpr const char* kPcie8897DefaultFirmwareName = "mrvl/pcie8897_uapsta.bin";

} // namespace

namespace MarvellW8897Transport {

void reset(MarvellW8897TransportState& state)
{
    state = MarvellW8897TransportState{};
}

bool configurePcieProfile(MarvellW8897TransportState& state, UInt16 vendorId, UInt16 deviceId)
{
    if (vendorId != kVendorIdMarvell88W8897 || deviceId != kDeviceIdMarvell88W8897) {
        state.pcieProfile = MarvellW8897TransportPcieProfile{};
        return false;
    }

    state.pcieProfile.kind = MarvellW8897TransportProfileKind::MwifiexPcie8897;
    state.pcieProfile.firmwareStatusReg = kPcieScratch3Reg;
    state.pcieProfile.driverReadyReg = kPcieScratch12Reg;
    state.pcieProfile.txReadPointerReg = kPcieRdDataPtrQ0Q1;
    state.pcieProfile.txWritePointerReg = kPcieWrDataPtrQ0Q1;
    state.pcieProfile.rxReadPointerReg = kPcieWrDataPtrQ0Q1;
    state.pcieProfile.rxWritePointerReg = kPcieRdDataPtrQ0Q1;
    state.pcieProfile.eventReadPointerReg = kPcieScratch10Reg;
    state.pcieProfile.eventWritePointerReg = kPcieScratch11Reg;
    state.pcieProfile.txRingMask = kPcie8897TxRingMask;
    state.pcieProfile.txRingWrapMask = kPcie8897TxRingWrapMask;
    state.pcieProfile.rxRingMask = kPcie8897RxRingMask;
    state.pcieProfile.rxRingWrapMask = kPcie8897RxRingWrapMask;
    state.pcieProfile.quirkFlags =
        kMarvellW8897TransportQuirkTxWritePointerReadback |
        kMarvellW8897TransportQuirkIgnoreBtcoexEvents;
    state.pcieProfile.defaultFirmwareName = kPcie8897DefaultFirmwareName;
    return true;
}

const MarvellW8897TransportPcieProfile* getPcieProfile(const MarvellW8897TransportState& state)
{
    if (state.pcieProfile.kind == MarvellW8897TransportProfileKind::None) {
        return nullptr;
    }

    return &state.pcieProfile;
}

bool readReg32FromBar(const MarvellW8897PciBarState& pciBars,
                      UInt32 barIndex,
                      UInt32 offset,
                      UInt32& valueOut)
{
    constexpr UInt32 kRegWidth = sizeof(UInt32);
    if (!MarvellW8897PciBars::isMmioAccessValid(pciBars, barIndex, offset, kRegWidth)) {
        return false;
    }

    volatile UInt32* reg =
        reinterpret_cast<volatile UInt32*>(
            reinterpret_cast<volatile UInt8*>(pciBars.bars[barIndex].mappedPtr) + offset);

    valueOut = OSSwapLittleToHostInt32(*reg);
    return true;
}

bool writeReg32ToBar(const MarvellW8897PciBarState& pciBars,
                     UInt32 barIndex,
                     UInt32 offset,
                     UInt32 value)
{
    constexpr UInt32 kRegWidth = sizeof(UInt32);
    if (!MarvellW8897PciBars::isMmioAccessValid(pciBars, barIndex, offset, kRegWidth)) {
        return false;
    }

    volatile UInt32* reg =
        reinterpret_cast<volatile UInt32*>(
            reinterpret_cast<volatile UInt8*>(pciBars.bars[barIndex].mappedPtr) + offset);

    *reg = OSSwapHostToLittleInt32(value);
    return true;
}

bool writeReg32ToBarWithFlush(const MarvellW8897PciBarState& pciBars,
                              MarvellW8897TransportState& transportState,
                              UInt32 barIndex,
                              UInt32 offset,
                              UInt32 value,
                              UInt32& readBack)
{
    if (!writeReg32ToBar(pciBars, barIndex, offset, value)) {
        return false;
    }

    if (!readReg32FromBar(pciBars, barIndex, offset, readBack)) {
        return false;
    }

    transportState.txRingWritePtr = value;
    return true;
}

bool getTransportState(const MarvellW8897TransportState& state,
                       UInt64 outState[MarvellW8897Regs::kTransportStateCount])
{
    if (!outState) {
        return false;
    }

    outState[0] = state.txRingWritePtr;
    outState[1] = state.txRingReadPtr;
    outState[2] = state.rxRingWritePtr;
    outState[3] = state.rxRingReadPtr;
    outState[4] = state.irqStatus;
    outState[5] = state.firmwareReady;
    outState[6] = state.lastEventId;
    outState[7] = state.btcoexEventsIgnored;
    return true;
}

} // namespace MarvellW8897Transport
