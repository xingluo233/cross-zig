#if defined(_WIN32)
#define SMOKE_EXPORT __declspec(dllexport)
#else
#define SMOKE_EXPORT
#endif

SMOKE_EXPORT const char* smoke_shared_value(void) {
    return "cross-smoke-shared";
}
