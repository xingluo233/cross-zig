#include <stddef.h>

#if defined(__ANDROID__) && (!defined(__ANDROID_API__) || !defined(__ANDROID_MIN_SDK_VERSION__))
#error "__ANDROID_API__ / __ANDROID_MIN_SDK_VERSION__ missing in translate-c"
#endif
