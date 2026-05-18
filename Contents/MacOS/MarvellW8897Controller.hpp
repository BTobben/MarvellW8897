//
//  MarvellW8897Controller.hpp
//  MarvellW8897
//
//  Created by Bryan on 16/11/2025.
//

#ifndef _MARVELL_W8897_CONTROLLER_HPP
#define _MARVELL_W8897_CONTROLLER_HPP

#include <IOKit/IOService.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOMemoryDescriptor.h>
#include "MarvellW8897Bringup.hpp"
#include "MarvellW8897Debug.hpp"
#include "MarvellW8897PciBars.hpp"
#include "MarvellW8897Transport.hpp"

class MarvellW8897Controller : public IOService
{
    OSDeclareDefaultStructors(MarvellW8897Controller)

private:
    IOPCIDevice*               fPCIDevice { nullptr };
    bool                       fDeviceOpen { false };
    MarvellW8897PciBarState     fPciBarState {};
    MarvellW8897TransportState  fTransportState {};
    MarvellW8897BringupResult   fBringupResult {};

    void releaseMappedBars();

public:
    IOService* probe(IOService* provider, SInt32* score) APPLE_KEXT_OVERRIDE;
    bool start(IOService* provider) APPLE_KEXT_OVERRIDE;
    void stop(IOService* provider) APPLE_KEXT_OVERRIDE;

    uint32_t readReg32(uint32_t offset);
    void     writeReg32(uint32_t offset, uint32_t value);
    bool     readReg32FromBar(uint32_t barIndex, uint32_t offset, uint32_t& valueOut);
    bool     writeReg32ToBar(uint32_t barIndex, uint32_t offset, uint32_t value);

    bool getPciIdentity(uint64_t outIdentity[10]) const;
    bool getBarInfoLegacy(uint32_t barIndex, uint64_t outInfo[8]) const;
    bool getBarInfoV2(uint32_t barIndex, uint64_t outInfo[11]) const;
    bool getTransportState(uint64_t outState[8]) const;
    bool getBringupResult(uint64_t outState[MarvellW8897Regs::kBringupResultCount]) const;
    bool getDebugAbiInfo(uint64_t outInfo[6]) const;

    bool writeReg32ToBarWithFlush(uint32_t barIndex, uint32_t offset, uint32_t value, uint32_t& readBack);

private:
    uint16_t fVendorId { 0 };
    uint16_t fDeviceId { 0 };
    uint16_t fSubVendorId { 0 };
    uint16_t fSubSystemId { 0 };
    uint8_t  fRevisionId { 0 };
    uint32_t fClassCode { 0 };
    uint16_t fCommand { 0 };
    uint16_t fStatus { 0 };
    uint8_t  fInterruptLine { 0 };
    uint8_t  fInterruptPin { 0 };
};

#endif
