//
//  MarvellW8897Kext.c
//  MarvellW8897Kext
//
//  Created by Bryan on 16/02/2026.
//

#include <mach/mach_types.h>

kern_return_t MarvellW8897Kext_start(kmod_info_t * ki, void *d);
kern_return_t MarvellW8897Kext_stop(kmod_info_t *ki, void *d);

kern_return_t MarvellW8897Kext_start(kmod_info_t * ki, void *d)
{
    return KERN_SUCCESS;
}

kern_return_t MarvellW8897Kext_stop(kmod_info_t *ki, void *d)
{
    return KERN_SUCCESS;
}
