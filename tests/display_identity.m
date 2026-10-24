// Exercise the real inventory, projection planner, operation generator and verifier
// against the invalid ID captured in last-projection-failure.json. No hardware calls.
#define DISPLAYCTL_TEST
#define main existingPlanningTests
#include "../macDisplayCtl.m"
#undef main

static NSDictionary *screen(uint32_t id, BOOL builtin, BOOL enabled, uint32_t mirrorOf) {
    return @{@"id": @(id), @"builtin": @(builtin), @"enabled": @(enabled),
             @"remembered": @NO, @"virtual": @NO, @"connected": @YES,
             @"uuid": [NSString stringWithFormat:@"screen-%u", id],
             @"name": [NSString stringWithFormat:@"Screen %u", id],
             @"vendor": @1552, @"product": @(id), @"serial": @0,
             @"mirror": @(mirrorOf != 0), @"mirrorOf": @(mirrorOf),
             @"width": @1000, @"logicalWidth": @1000, @"height": @700,
             @"x": @((id - 1) * 1000), @"y": @0, @"main": @(builtin)};
}

int main(void) {
    @autoreleasepool {
        unsigned checks = 0;
        NSDictionary *poison = @{@"id": @14, @"builtin": @YES, @"enabled": @NO,
            @"remembered": @YES, @"virtual": @NO, @"connected": @YES,
            @"name": @"Built-in display", @"vendor": @(UINT32_MAX),
            @"product": @(UINT32_MAX), @"serial": @(UINT32_MAX),
            @"mirrorOf": @(UINT32_MAX), @"width": @0, @"height": @0};
        NSArray *real = @[screen(1, YES, YES, 0), screen(2, NO, YES, 0), screen(3, NO, YES, 0)];
        NSArray *polluted = [real arrayByAddingObject:poison];
        reconnectAssert(!displayFlag(UINT32_MAX) && displayFlag(1) && !displayFlag(0), @"invalid boolean sentinel is not true", &checks);
        reconnectAssert(!validDisplayIdentity(poison), @"captured invalid ID 14 rejected", &checks);
        reconnectAssert([currentDisplayRows(polluted) isEqual:real], @"cached invalid builtin removed", &checks);
        NSMutableDictionary *livePoison = [poison mutableCopy]; livePoison[@"remembered"] = @NO;
        reconnectAssert([currentDisplayRows([real arrayByAddingObject:livePoison]) isEqual:real], @"invalid live entry also rejected", &checks);
        NSMutableDictionary *legacyBuiltin = [poison mutableCopy];
        [legacyBuiltin removeObjectForKey:@"vendor"]; [legacyBuiltin removeObjectForKey:@"product"];
        reconnectAssert([currentDisplayRows([real arrayByAddingObject:legacyBuiltin]) isEqual:real], @"live builtin outranks identity-less cached builtin", &checks);
        NSMutableDictionary *serialSentinel = [real[1] mutableCopy]; serialSentinel[@"serial"] = @(UINT32_MAX);
        reconnectAssert(validDisplayIdentity(serialSentinel), @"valid vendor/product with unknown serial remains usable", &checks);
        NSMutableDictionary *softOff = [real[0] mutableCopy]; softOff[@"enabled"] = @NO; softOff[@"remembered"] = @YES;
        reconnectAssert([currentDisplayRows(@[softOff]) count] == 1, @"genuine disabled builtin can still recover", &checks);

        NSString *error = nil;
        for (NSString *mode in @[@"internal", @"external", @"duplicate", @"extend"]) {
            NSDictionary *configuration = projectionPlan(polluted, mode, nil, &error);
            reconnectAssert([configuration[@"builtin"][@"id"] isEqual:@1], @"all modes choose the real builtin", &checks);
            NSArray *operations = projectionOperations(configuration, real, &error);
            reconnectAssert(operations != nil, @"real displays pass preflight", &checks);
            for (NSDictionary *operation in operations)
                reconnectAssert(![operation[@"id"] isEqual:@14] && ![operation[@"source"] isEqual:@14], @"no transaction references phantom ID", &checks);
        }
        NSDictionary *mirror = projectionPlan(polluted, @"duplicate", nil, &error);
        NSArray *mirrorOps = projectionOperations(mirror, real, &error);
        reconnectAssert(mirrorOps.count == 2 && [mirrorOps[0][@"source"] isEqual:@1] &&
                        [mirrorOps[1][@"source"] isEqual:@1], @"both external screens receive mirror operations", &checks);
        reconnectAssert(projectionStateIssue(mirror, @[screen(1, YES, YES, 0), screen(2, NO, YES, 1), screen(3, NO, YES, 1)]) == nil,
                        @"successful three-screen mirror is not a failure", &checks);
        reconnectAssert(projectionStateIssue(mirror, @[screen(1, YES, YES, 2), screen(2, NO, YES, 0), screen(3, NO, YES, 2)]) == nil,
                        @"system-selected external mirror master accepted", &checks);
        reconnectAssert(projectionStateIssue(mirror, @[screen(1, YES, YES, 0), screen(2, NO, YES, 1), screen(3, NO, YES, 0)]) != nil,
                        @"partial mirror is still detected", &checks);
        reconnectAssert(projectionOperations(mirror, @[real[0], real[1], screen(3, NO, NO, 0)], &error) == nil,
                        @"all targets must be ready before layout change", &checks);
        NSMutableDictionary *changedID = [real[2] mutableCopy]; changedID[@"id"] = @9;
        NSDictionary *extended = projectionPlan(polluted, @"extend", nil, &error);
        reconnectAssert(projectionStateIssue(extended, @[real[0], real[1], changedID]) == nil,
                        @"UUID resolves new display ID", &checks);
        reconnectAssert(projectionStateIssue(projectionPlan(polluted, @"external", nil, &error),
                        @[screen(1, YES, NO, 0), real[1], screen(3, NO, NO, 0)]) != nil,
                        @"external-only does not succeed with a missing second external", &checks);
        NSMutableDictionary *disabledInternal = [real[0] mutableCopy];
        disabledInternal[@"enabled"] = @NO;
        disabledInternal[@"online"] = @NO;
        NSMutableDictionary *sleepingExternal = [real[1] mutableCopy];
        sleepingExternal[@"enabled"] = @NO; sleepingExternal[@"online"] = @YES;
        sleepingExternal[@"asleep"] = @YES; sleepingExternal[@"connected"] = @NO;
        NSArray *sleepUnplug = @[disabledInternal, sleepingExternal];
        reconnectAssert(needsNoExternalRecovery(sleepUnplug, 0), @"open lid and disconnected external permit recovery despite stale sleep flag", &checks);
        reconnectAssert(!needsNoExternalRecovery(sleepUnplug, 1), @"closed lid never forced on", &checks);
        reconnectAssert(!needsNoExternalRecovery(sleepUnplug, -1), @"unknown lid not forced on", &checks);
        GuardState state = newGuardState(); NSString *reason = nil;
        reconnectAssert(recoveryPlan(sleepUnplug, 0, 10, &state, &reason).count == 0, @"unplug recovery has fast stability delay", &checks);
        NSArray *recover = recoveryPlan(sleepUnplug, 0, 10.31, &state, &reason);
        reconnectAssert(recover.count == 1 && [recover[0][@"display"][@"id"] isEqual:@1] &&
                        [recover[0][@"enabled"] boolValue], @"sleep-unplug recovery enables only internal", &checks);
        sleepingExternal[@"connected"] = @YES;
        reconnectAssert(!needsNoExternalRecovery(sleepUnplug, 0) &&
                        recoveryPlan(sleepUnplug, 0, 12, &state, &reason).count == 0, @"connected sleeping external retains normal sleep", &checks);
        sleepingExternal[@"connected"] = NSNull.null;
        reconnectAssert(!needsNoExternalRecovery(sleepUnplug, 0), @"unknown connection does not override sleep", &checks);
        disabledInternal[@"enabled"] = @YES; disabledInternal[@"online"] = @YES; disabledInternal[@"asleep"] = @YES;
        reconnectAssert(!needsNoExternalRecovery(@[disabledInternal], 0) &&
                        recoveryPlan(@[disabledInternal], 0, 15, &state, &reason).count == 0, @"normally sleeping enabled internal is not repeatedly awakened", &checks);
        disabledInternal[@"enabled"] = @NO; disabledInternal[@"online"] = @NO; disabledInternal[@"asleep"] = @NO;
        reconnectAssert(needsNoExternalRecovery(@[disabledInternal], 0), @"no external records still permits internal rescue", &checks);
        reconnectAssert(!needsNoExternalRecovery(@[], 0), @"no known internal never guesses an ID", &checks);
        state = newGuardState();
        recoveryAttemptedWithPolicy(&state, 20, YES);
        reconnectAssert(state.nextAttempt == 20.2, @"fast retry starts at 200ms", &checks);
        recoveryAttemptedWithPolicy(&state, 20.2, YES);
        reconnectAssert(state.nextAttempt == 20.7, @"fast retry backs off to 500ms", &checks);
        recoveryAttemptedWithPolicy(&state, 20.7, YES);
        reconnectAssert(state.nextAttempt == 35.7, @"third fast failure enters short cooldown", &checks);
        printf("%u display identity, sleep-unplug recovery and projection regressions passed.\n", checks);
        return 0;
    }
}
