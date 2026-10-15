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
        printf("%u display identity and real projection pipeline regressions passed.\n", checks);
        return 0;
    }
}
