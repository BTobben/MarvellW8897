//
//  MarvellW8897Controller.cpp
//  MarvellW8897
//
//  Created by Bryan on 16/11/2025.
//

#include "MarvellW8897Controller.hpp"
#include <IOKit/IOLib.h>

#define super IOService
OSDefineMetaClassAndStructors(MarvellW8897Controller, IOService)

void MarvellW8897Controller::releaseMappedBars()
{
    MarvellW8897PciBars::release(fPciBarState);
}

IOService* MarvellW8897Controller::probe(IOService* provider, SInt32* score)
{
    IOService* matched = super::probe(provider, score);

    if (matched) {
        const char* providerName = provider ? provider->getName() : "<null>";
        IOLog("MarvellW8897: probe matched provider=%s score=%d\n",
              providerName,
              score ? *score : -1);
    } else {
        IOLog("MarvellW8897: probe did not match\n");
    }

    return matched;
}

bool MarvellW8897Controller::start(IOService* provider)
{
    if (!super::start(provider)) {
        IOLog("MarvellW8897: super::start() failed\n");
        return false;
    }

    IOLog("MarvellW8897: start() called\n");

    fPCIDevice = OSDynamicCast(IOPCIDevice, provider);
    if (!fPCIDevice) {
        IOLog("MarvellW8897: provider is not IOPCIDevice\n");
        return false;
    }

    fPCIDevice->retain();

    if (!fPCIDevice->open(this)) {
        IOLog("MarvellW8897: failed to open provider\n");
        fPCIDevice->release();
        fPCIDevice = nullptr;
        return false;
    }
    fDeviceOpen = true;

    fVendorId = fPCIDevice->configRead16(kIOPCIConfigVendorID);
    fDeviceId = fPCIDevice->configRead16(kIOPCIConfigDeviceID);
    fSubVendorId = fPCIDevice->configRead16(kIOPCIConfigSubSystemVendorID);
    fSubSystemId = fPCIDevice->configRead16(kIOPCIConfigSubSystemID);
    fRevisionId = fPCIDevice->configRead8(kIOPCIConfigRevisionID);
    fClassCode = fPCIDevice->configRead32(kIOPCIConfigRevisionID) >> 8;
    fCommand = fPCIDevice->configRead16(kIOPCIConfigCommand);
    fStatus = fPCIDevice->configRead16(kIOPCIConfigStatus);
    fInterruptLine = fPCIDevice->configRead8(kIOPCIConfigInterruptLine);
    fInterruptPin = fPCIDevice->configRead8(kIOPCIConfigInterruptPin);

    const char* providerName = fPCIDevice->getName();
    IOLog("MarvellW8897: provider=%s\n", providerName ? providerName : "<unknown>");
    IOLog("MarvellW8897: PCI IDs vendor=%04x device=%04x subVendor=%04x subSystem=%04x rev=%02x class=%06x\n",
          fVendorId,
          fDeviceId,
          fSubVendorId,
          fSubSystemId,
          fRevisionId,
          fClassCode);
    IOLog("MarvellW8897: PCI cmd=%04x status=%04x intLine=%02x intPin=%02x\n",
          fCommand,
          fStatus,
          fInterruptLine,
          fInterruptPin);

    fPCIDevice->setMemoryEnable(true);
    fPCIDevice->setBusMasterEnable(true);
    fCommand = fPCIDevice->configRead16(kIOPCIConfigCommand);
    fStatus = fPCIDevice->configRead16(kIOPCIConfigStatus);
    IOLog("MarvellW8897: memory and bus-master enabled (cmd=%04x status=%04x)\n",
          fCommand,
          fStatus);

    if (!MarvellW8897PciBars::mapDeviceBars(fPCIDevice, fPciBarState)) {
        releaseMappedBars();
        if (fDeviceOpen) {
            fPCIDevice->close(this);
            fDeviceOpen = false;
        }
        fPCIDevice->setBusMasterEnable(false);
        fPCIDevice->setMemoryEnable(false);
        fPCIDevice->release();
        fPCIDevice = nullptr;
        return false;
    }

    MarvellW8897Transport::reset(fTransportState);
    MarvellW8897Bringup::reset(fBringupResult);

    if (!MarvellW8897Transport::configurePcieProfile(fTransportState, fVendorId, fDeviceId)) {
        IOLog("MarvellW8897: no grounded mwifiex-style PCIe profile for vendor=%04x device=%04x\n",
              fVendorId,
              fDeviceId);
    }

    if (!MarvellW8897Bringup::run(fPciBarState, fTransportState, fBringupResult)) {
        IOLog("MarvellW8897: bring-up failed stage=%s reason=%s bar=%u offset=0x%x reads=0x%08x writes=0x%08x polls=%u\n",
              MarvellW8897Bringup::stageName(fBringupResult.stage),
              MarvellW8897Bringup::failureReasonName(fBringupResult.failureReason),
              fBringupResult.lastBarIndex,
              fBringupResult.lastRegisterOffset,
              fBringupResult.lastValueRead,
              fBringupResult.lastValueWritten,
              fBringupResult.pollIterations);
        releaseMappedBars();
        if (fDeviceOpen) {
            fPCIDevice->close(this);
            fDeviceOpen = false;
        }
        fPCIDevice->setBusMasterEnable(false);
        fPCIDevice->setMemoryEnable(false);
        fPCIDevice->release();
        fPCIDevice = nullptr;
        return false;
    }

    IOLog("MarvellW8897: bring-up stage=%s reason=%s resetAttempted=%d readyObserved=%d bar=%u offset=0x%x reads=0x%08x writes=0x%08x polls=%u\n",
          MarvellW8897Bringup::stageName(fBringupResult.stage),
          MarvellW8897Bringup::failureReasonName(fBringupResult.failureReason),
          fBringupResult.resetAttempted ? 1 : 0,
          fBringupResult.readyObserved ? 1 : 0,
          fBringupResult.lastBarIndex,
          fBringupResult.lastRegisterOffset,
          fBringupResult.lastValueRead,
          fBringupResult.lastValueWritten,
          fBringupResult.pollIterations);

    registerService();
    return true;
}

void MarvellW8897Controller::stop(IOService* provider)
{
    IOLog("MarvellW8897: stop() called\n");

    releaseMappedBars();

    if (fPCIDevice) {
        fPCIDevice->setBusMasterEnable(false);
        fPCIDevice->setMemoryEnable(false);

        if (fDeviceOpen) {
            fPCIDevice->close(this);
            fDeviceOpen = false;
        }

        fPCIDevice->release();
        fPCIDevice = nullptr;
    }

    MarvellW8897Transport::reset(fTransportState);
    MarvellW8897Bringup::reset(fBringupResult);

    super::stop(provider);
}

bool MarvellW8897Controller::readReg32FromBar(uint32_t barIndex, uint32_t offset, uint32_t& valueOut)
{
    return MarvellW8897Transport::readReg32FromBar(fPciBarState, barIndex, offset, valueOut);
}

bool MarvellW8897Controller::writeReg32ToBar(uint32_t barIndex, uint32_t offset, uint32_t value)
{
    return MarvellW8897Transport::writeReg32ToBar(fPciBarState, barIndex, offset, value);
}

uint32_t MarvellW8897Controller::readReg32(uint32_t offset)
{
    uint32_t value = 0xffffffffU;
    if (!readReg32FromBar(0, offset, value)) {
        return 0xffffffffU;
    }

    return value;
}

void MarvellW8897Controller::writeReg32(uint32_t offset, uint32_t value)
{
    (void)writeReg32ToBar(0, offset, value);
}

bool MarvellW8897Controller::getPciIdentity(uint64_t outIdentity[10]) const
{
    if (!outIdentity) {
        return false;
    }

    outIdentity[0] = fVendorId;
    outIdentity[1] = fDeviceId;
    outIdentity[2] = fSubVendorId;
    outIdentity[3] = fSubSystemId;
    outIdentity[4] = fRevisionId;
    outIdentity[5] = fClassCode;
    outIdentity[6] = fCommand;
    outIdentity[7] = fStatus;
    outIdentity[8] = fInterruptLine;
    outIdentity[9] = fInterruptPin;
    return true;
}

bool MarvellW8897Controller::getBarInfoLegacy(uint32_t barIndex, uint64_t outInfo[8]) const
{
    return MarvellW8897PciBars::getBarInfoLegacy(fPciBarState, barIndex, outInfo);
}

bool MarvellW8897Controller::getBarInfoV2(uint32_t barIndex, uint64_t outInfo[11]) const
{
    return MarvellW8897PciBars::getBarInfoV2(fPciBarState, barIndex, outInfo);
}

bool MarvellW8897Controller::writeReg32ToBarWithFlush(uint32_t barIndex,
                                                      uint32_t offset,
                                                      uint32_t value,
                                                      uint32_t& readBack)
{
    return MarvellW8897Transport::writeReg32ToBarWithFlush(
        fPciBarState,
        fTransportState,
        barIndex,
        offset,
        value,
        readBack);
}

bool MarvellW8897Controller::getDebugAbiInfo(uint64_t outInfo[6]) const
{
    return MarvellW8897Debug::getDebugAbiInfo(outInfo);
}

bool MarvellW8897Controller::getTransportState(uint64_t outState[8]) const
{
    return MarvellW8897Transport::getTransportState(fTransportState, outState);
}

bool MarvellW8897Controller::getBringupResult(
    uint64_t outState[MarvellW8897Regs::kBringupResultCount]) const
{
    if (!outState) {
        return false;
    }

    // Read-only ABI field order:
    // 0 stage, 1 failureReason, 2 lastBarIndex, 3 lastRegisterOffset,
    // 4 lastValueRead, 5 lastValueWritten, 6 pollIterations,
    // 7 firmwareStatusValue, 8 driverReadyValue, 9 quirkFlags,
    // 10 resetAttempted, 11 readyObserved.
    outState[0] = static_cast<uint64_t>(fBringupResult.stage);
    outState[1] = static_cast<uint64_t>(fBringupResult.failureReason);
    outState[2] = fBringupResult.lastBarIndex;
    outState[3] = fBringupResult.lastRegisterOffset;
    outState[4] = fBringupResult.lastValueRead;
    outState[5] = fBringupResult.lastValueWritten;
    outState[6] = fBringupResult.pollIterations;
    outState[7] = fBringupResult.firmwareStatusValue;
    outState[8] = fBringupResult.driverReadyValue;
    outState[9] = fBringupResult.quirkFlags;
    outState[10] = fBringupResult.resetAttempted ? 1 : 0;
    outState[11] = fBringupResult.readyObserved ? 1 : 0;
    return true;
}
