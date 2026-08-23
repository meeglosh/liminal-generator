/*
 * AutoRenderBootstrap.c
 * LiminalGenerator
 *
 * DEBUG-only smoke-test entry point. `__attribute__((constructor))` is run
 * by dyld before `main()`/`UIApplicationMain`, so this fires on process
 * launch with no UI interaction required. Delegates immediately to the
 * `@_cdecl`-exported Swift function in AutoRenderDebugHarness.swift, which
 * checks the "LG_AUTORENDER" env var and no-ops unless it is set to "1".
 * Kept as a trivial one-line shim so all real logic (and the DEBUG guard)
 * lives in Swift.
 */

#ifdef DEBUG
extern void lg_autorender_bootstrap(void);

__attribute__((constructor))
static void lg_autorender_ctor(void) {
    lg_autorender_bootstrap();
}
#endif
