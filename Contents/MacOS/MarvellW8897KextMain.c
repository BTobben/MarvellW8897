#include <mach/mach_types.h>

kern_return_t MarvellW8897_start(kmod_info_t *ki, void *d)
{
    (void)ki;
    (void)d;
    return KERN_SUCCESS;
}

kern_return_t MarvellW8897_stop(kmod_info_t *ki, void *d)
{
    (void)ki;
    (void)d;
    return KERN_SUCCESS;
}
