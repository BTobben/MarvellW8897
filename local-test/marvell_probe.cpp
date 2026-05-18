#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <cerrno>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace {
constexpr const char *kServiceName = "MarvellW8897Controller";
constexpr kern_return_t kUnsupported = static_cast<kern_return_t>(0xe00002c7);

constexpr uint32_t kMarvellMethodGetPciInfo = 0;
constexpr uint32_t kMarvellMethodGetBarInfoLegacy = 1;
constexpr uint32_t kMarvellMethodReadReg32FromBar = 2;
constexpr uint32_t kMarvellMethodGetBarInfoV2 = 4;
constexpr uint32_t kLegacyMethodGetTransportState = 4;
constexpr uint32_t kMarvellMethodGetTransportState = 5;
constexpr uint32_t kMarvellMethodGetDebugAbiInfo = 7;
constexpr uint32_t kMarvellMethodGetBringupResult = 8;
constexpr uint32_t kBringupResultCount = 12;
constexpr uint32_t kMaxBars = 6;
constexpr uint32_t kBarInfoV2FieldCount = 11;
constexpr uint64_t kInvalidResourceIndex = 0xffffffffULL;

const char* bringupStageName(uint64_t stage)
{
    switch (stage) {
        case 0: return "not-started";
        case 1: return "pci-enabled";
        case 2: return "bars-mapped";
        case 3: return "sanity-checked";
        case 4: return "reset-attempted";
        case 5: return "reset-observed";
        case 6: return "ready-observed";
        case 7: return "timed-out";
        case 8: return "unsupported";
        case 9: return "failed";
        default: return "unknown";
    }
}

const char* bringupFailureReasonName(uint64_t reason)
{
    switch (reason) {
        case 0: return "none";
        case 1: return "invalid-bar";
        case 2: return "invalid-offset";
        case 3: return "read-failed";
        case 4: return "write-failed";
        case 5: return "verify-mismatch";
        case 6: return "timeout";
        case 7: return "no-grounded-reset-semantic";
        case 8: return "no-transport-profile";
        case 9: return "unsupported-bar0";
        default: return "unknown";
    }
}

bool selectorSupported(uint64_t bitmap, uint32_t selector)
{
    return (bitmap & (1ULL << selector)) != 0;
}

struct ProbeOptions {
    bool readBarReg { false };
    uint32_t readBar { 0 };
    uint32_t readOffset { 0 };
};

struct BarInfoSnapshot {
    bool valid { false };
    uint64_t fields[kBarInfoV2FieldCount] {};
};

void printUsage(const char* argv0)
{
    std::printf("Usage: %s [--read-bar-reg <bar> <offset>]\n", argv0);
    std::printf("\n");
    std::printf("Default mode prints PCI/BAR/bring-up/transport diagnostics without explicit extra MMIO reads.\n");
    std::printf("--read-bar-reg performs one explicit read-only 32-bit MMIO read from one selected BAR.\n");
    std::printf("Offsets may be decimal or 0x-prefixed hexadecimal and must be 4-byte aligned.\n");
    std::printf("Nonzero or high-entropy-looking values are not proof of semantic mwifiex register state.\n");
}

bool parseU32(const char* text, uint32_t& valueOut)
{
    if (!text || text[0] == '\0') {
        return false;
    }

    errno = 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(text, &end, 0);
    if (errno != 0 || !end || *end != '\0' || parsed > 0xffffffffULL) {
        return false;
    }

    valueOut = static_cast<uint32_t>(parsed);
    return true;
}

bool parseOptions(int argc, char** argv, ProbeOptions& options)
{
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
            printUsage(argv[0]);
            std::exit(0);
        }

        if (std::strcmp(argv[i], "--read-bar-reg") == 0) {
            if (options.readBarReg || (i + 2) >= argc) {
                return false;
            }

            uint32_t bar = 0;
            uint32_t offset = 0;
            if (!parseU32(argv[i + 1], bar) || !parseU32(argv[i + 2], offset)) {
                return false;
            }
            if ((offset & 0x3U) != 0) {
                std::printf("Refusing unaligned --read-bar-reg offset 0x%x; use a 4-byte aligned offset.\n", offset);
                return false;
            }

            options.readBarReg = true;
            options.readBar = bar;
            options.readOffset = offset;
            i += 2;
            continue;
        }

        return false;
    }

    return true;
}

const char* barInfoFieldName(uint32_t index)
{
    switch (index) {
        case 0: return "barIndex";
        case 1: return "rawLow";
        case 2: return "rawHigh";
        case 3: return "configValue";
        case 4: return "present";
        case 5: return "isMemory";
        case 6: return "is64Bit";
        case 7: return "isContinuation";
        case 8: return "mappedResource";
        case 9: return "length";
        case 10: return "physicalAddress";
        default: return "unknown";
    }
}

bool explicitReadBarReg(io_connect_t conn, uint32_t bar, uint32_t offset)
{
    std::printf("WARNING: explicit read-only BAR MMIO diagnostic requested by operator.\n");
    std::printf("         This performs exactly one 32-bit read from BAR %u offset 0x%x; no writes are issued.\n",
                bar,
                offset);
    std::printf("         Do not loop this command or scan BARs automatically on unstable hardware.\n");
    std::printf("         Treat nonzero/high-entropy values as suspicious until source-grounded.\n");

    uint64_t in[2] = {bar, offset};
    uint64_t out[1] = {};
    uint32_t outCount = 1;
    const kern_return_t kr = IOConnectCallScalarMethod(conn,
                                                       kMarvellMethodReadReg32FromBar,
                                                       in,
                                                       2,
                                                       out,
                                                       &outCount);
    std::printf("readReg32FromBar(bar=%u, off=0x%x): kr=0x%x outCount=%u",
                bar,
                offset,
                kr,
                outCount);
    if (kr == KERN_SUCCESS && outCount > 0) {
        std::printf(" value=0x%08llx", (unsigned long long)out[0]);
    }
    std::printf("\n");
    return kr == KERN_SUCCESS;
}

bool tryGetBarInfo(io_connect_t conn, uint32_t selector, uint32_t bar, uint32_t want, BarInfoSnapshot* snapshot)
{
    uint64_t in[1] = {bar};
    uint64_t out[11] = {};
    uint32_t outCount = want;
    const kern_return_t kr = IOConnectCallScalarMethod(conn, selector, in, 1, out, &outCount);

    std::printf("selector=%u getBarInfo(bar=%u, want=%u): kr=0x%x outCount=%u\n",
                selector,
                bar,
                want,
                kr,
                outCount);

    if (kr != KERN_SUCCESS) {
        return false;
    }

    if (snapshot && outCount >= kBarInfoV2FieldCount) {
        snapshot->valid = true;
        for (uint32_t i = 0; i < kBarInfoV2FieldCount; ++i) {
            snapshot->fields[i] = out[i];
        }
    }

    for (uint32_t i = 0; i < outCount; ++i) {
        std::printf("  bar[%u][%u] %-16s = 0x%llx\n",
                    bar,
                    i,
                    barInfoFieldName(i),
                    (unsigned long long)out[i]);
    }
    return true;
}

void printBarSummary(const BarInfoSnapshot snapshots[kMaxBars])
{
    std::printf("BAR passive metadata summary (no MMIO reads):\n");

    bool sawMappedMemory = false;
    for (uint32_t bar = 0; bar < kMaxBars; ++bar) {
        const BarInfoSnapshot& snapshot = snapshots[bar];
        if (!snapshot.valid) {
            std::printf("  BAR%u: no v2 metadata\n", bar);
            continue;
        }

        const bool present = snapshot.fields[4] != 0;
        const bool isMemory = snapshot.fields[5] != 0;
        const bool is64Bit = snapshot.fields[6] != 0;
        const bool isContinuation = snapshot.fields[7] != 0;
        const uint64_t mappedResource = snapshot.fields[8];
        const uint64_t length = snapshot.fields[9];
        const uint64_t physicalAddress = snapshot.fields[10];
        const bool mapped = mappedResource != kInvalidResourceIndex && length != 0;

        const char* type = isContinuation ? "continuation" : (isMemory ? "memory" : "io");
        std::printf("  BAR%u: type=%s present=%llu width=%s mappedResource=%s",
                    bar,
                    type,
                    (unsigned long long)(present ? 1 : 0),
                    isContinuation ? "-" : (is64Bit ? "64" : "32"),
                    mapped ? "" : "none");
        if (mapped) {
            std::printf("%llu paddr=0x%llx len=0x%llx",
                        (unsigned long long)mappedResource,
                        (unsigned long long)physicalAddress,
                        (unsigned long long)length);
        }
        std::printf(" rawLow=0x%llx rawHigh=0x%llx\n",
                    (unsigned long long)snapshot.fields[1],
                    (unsigned long long)snapshot.fields[2]);

        if (present && isMemory && !isContinuation && mapped) {
            sawMappedMemory = true;
            std::printf("    candidate: mapped memory BAR%u -> resource%llu, base/len 0x%llx/0x%llx\n",
                        bar,
                        (unsigned long long)mappedResource,
                        (unsigned long long)physicalAddress,
                        (unsigned long long)length);
        }
    }

    if (!sawMappedMemory) {
        std::printf("  no mapped memory BAR candidates reported by v2 metadata\n");
    }

    std::printf("  note: this summary uses passive BAR metadata only; structural candidates are not semantic proof.\n");
}
}

int main(int argc, char** argv)
{
    ProbeOptions options {};
    if (!parseOptions(argc, argv, options)) {
        printUsage(argv[0]);
        return 2;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kServiceName));
    if (!service) {
        std::printf("No %s service found\n", kServiceName);
        return 1;
    }

    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);

    if (kr != KERN_SUCCESS) {
        std::printf("IOServiceOpen failed: 0x%x\n", kr);
        return 1;
    }

    {
        uint64_t out[10] = {};
        uint32_t outCount = 10;
        kr = IOConnectCallScalarMethod(conn, kMarvellMethodGetPciInfo, nullptr, 0, out, &outCount);
        std::printf("getPciInfo: kr=0x%x outCount=%u\n", kr, outCount);
        if (kr == KERN_SUCCESS) {
            for (uint32_t i = 0; i < outCount; ++i) {
                std::printf("  pci[%u] = 0x%llx\n", i, (unsigned long long)out[i]);
            }
        }
    }

    uint64_t abiInfo[6] = {};
    uint32_t abiOutCount = 6;
    bool haveAbiInfo = false;
    uint64_t selectorBitmap = 0;
    uint32_t legacyBarCount = 8;
    uint32_t v2BarCount = 11;
    uint32_t transportCount = 8;

    kr = IOConnectCallScalarMethod(conn, kMarvellMethodGetDebugAbiInfo, nullptr, 0, abiInfo, &abiOutCount);
    std::printf("getDebugAbiInfo: kr=0x%x outCount=%u\n", kr, abiOutCount);
    if (kr == KERN_SUCCESS && abiOutCount >= 6) {
        haveAbiInfo = true;
        selectorBitmap = abiInfo[2];
        legacyBarCount = static_cast<uint32_t>(abiInfo[3]);
        v2BarCount = static_cast<uint32_t>(abiInfo[4]);
        transportCount = static_cast<uint32_t>(abiInfo[5]);

        for (uint32_t i = 0; i < abiOutCount; ++i) {
            std::printf("  abi[%u] = 0x%llx\n", i, (unsigned long long)abiInfo[i]);
        }
    } else if (kr == kUnsupported) {
        std::printf("  getDebugAbiInfo not supported by loaded kext; using fallback probing\n");
    }

    if (options.readBarReg) {
        if (haveAbiInfo && !selectorSupported(selectorBitmap, kMarvellMethodReadReg32FromBar)) {
            std::printf("explicit BAR read requested, but readReg32FromBar is not advertised by loaded ABI\n");
        } else {
            const bool readOk = explicitReadBarReg(conn, options.readBar, options.readOffset);
            if (!readOk) {
                std::printf("  explicit BAR read failed; kernel-side BAR existence, memory, mapping, continuation, alignment, and bounds checks may have rejected it.\n");
            }
        }
    }

    BarInfoSnapshot barSnapshots[kMaxBars] {};

    for (uint32_t bar = 0; bar < kMaxBars; ++bar) {
        bool ok = false;

        if (haveAbiInfo) {
            if (selectorSupported(selectorBitmap, kMarvellMethodGetBarInfoV2)) {
                ok = tryGetBarInfo(conn, kMarvellMethodGetBarInfoV2, bar, v2BarCount, &barSnapshots[bar]);
            }
            if (!ok && selectorSupported(selectorBitmap, kMarvellMethodGetBarInfoLegacy)) {
                ok = tryGetBarInfo(conn, kMarvellMethodGetBarInfoLegacy, bar, legacyBarCount, nullptr);
            }
        } else {
            if (!ok) {
                ok = tryGetBarInfo(conn, kMarvellMethodGetBarInfoV2, bar, 11, &barSnapshots[bar]);
            }
            if (!ok) {
                const uint32_t wants[] = {11u, 10u, 8u};
                for (uint32_t want : wants) {
                    if (tryGetBarInfo(conn, kMarvellMethodGetBarInfoLegacy, bar, want, nullptr)) {
                        ok = true;
                        break;
                    }
                }
            }
        }

        if (!ok) {
            std::printf("  getBarInfo(bar=%u): no compatible ABI found\n", bar);
        }
    }

    printBarSummary(barSnapshots);

    {
        // Read-only bring-up result ABI field order:
        // 0 stage, 1 failureReason, 2 lastBarIndex, 3 lastRegisterOffset,
        // 4 lastValueRead, 5 lastValueWritten, 6 pollIterations,
        // 7 firmwareStatusValue, 8 driverReadyValue, 9 quirkFlags,
        // 10 resetAttempted, 11 readyObserved.
        uint64_t out[kBringupResultCount] = {};
        uint32_t outCount = kBringupResultCount;
        bool shouldTry = haveAbiInfo &&
                         selectorSupported(selectorBitmap, kMarvellMethodGetBringupResult);

        if (!shouldTry) {
            std::printf("getBringupResult: not advertised by loaded ABI\n");
        }

        if (shouldTry) {
            kr = IOConnectCallScalarMethod(conn,
                                           kMarvellMethodGetBringupResult,
                                           nullptr,
                                           0,
                                           out,
                                           &outCount);
            std::printf("getBringupResult: kr=0x%x outCount=%u\n", kr, outCount);
            if (kr == KERN_SUCCESS && outCount >= kBringupResultCount) {
                std::printf("  bringup[0] stage = 0x%llx (%s)\n",
                            (unsigned long long)out[0],
                            bringupStageName(out[0]));
                std::printf("  bringup[1] failureReason = 0x%llx (%s)\n",
                            (unsigned long long)out[1],
                            bringupFailureReasonName(out[1]));
                std::printf("  bringup[2] lastBarIndex = 0x%llx\n", (unsigned long long)out[2]);
                std::printf("  bringup[3] lastRegisterOffset = 0x%llx\n", (unsigned long long)out[3]);
                std::printf("  bringup[4] lastValueRead = 0x%llx\n", (unsigned long long)out[4]);
                std::printf("  bringup[5] lastValueWritten = 0x%llx\n", (unsigned long long)out[5]);
                std::printf("  bringup[6] pollIterations = 0x%llx\n", (unsigned long long)out[6]);
                std::printf("  bringup[7] firmwareStatusValue = 0x%llx\n", (unsigned long long)out[7]);
                std::printf("  bringup[8] driverReadyValue = 0x%llx\n", (unsigned long long)out[8]);
                std::printf("  bringup[9] quirkFlags = 0x%llx\n", (unsigned long long)out[9]);
                std::printf("  bringup[10] resetAttempted = 0x%llx\n", (unsigned long long)out[10]);
                std::printf("  bringup[11] readyObserved = 0x%llx\n", (unsigned long long)out[11]);
            } else if (kr == kUnsupported) {
                std::printf("  getBringupResult not supported by loaded kext\n");
            }
        }
    }

    {
        uint64_t out[8] = {};
        uint32_t outCount = transportCount;
        uint32_t selector = kMarvellMethodGetTransportState;
        bool shouldTry = true;

        if (haveAbiInfo && !selectorSupported(selectorBitmap, kMarvellMethodGetTransportState)) {
            shouldTry = false;
            std::printf("getTransportState: not advertised by loaded ABI\n");
        }

        if (shouldTry) {
            kr = IOConnectCallScalarMethod(conn, selector, nullptr, 0, out, &outCount);
            if (!haveAbiInfo && kr == kUnsupported) {
                selector = kLegacyMethodGetTransportState;
                outCount = 8;
                kr = IOConnectCallScalarMethod(conn, selector, nullptr, 0, out, &outCount);
            }

            std::printf("getTransportState(selector=%u): kr=0x%x outCount=%u\n", selector, kr, outCount);
            if (kr == KERN_SUCCESS) {
                for (uint32_t i = 0; i < outCount; ++i) {
                    std::printf("  transport[%u] = 0x%llx\n", i, (unsigned long long)out[i]);
                }
            } else if (kr == kUnsupported) {
                std::printf("  getTransportState not supported by loaded kext\n");
            }
        }
    }

    IOServiceClose(conn);
    return 0;
}
