#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>

@interface TFNScrollingSegmentedViewController : UIViewController
- (void)setSelectedIndex:(NSInteger)index;
- (NSInteger)selectedIndex;
@end

@interface THFTimelineViewController : UIViewController
- (void)_pullToRefresh:(id)sender;
@end

static char kXNFPagedScrollViewsKey;
static char kXNFLastPagingRescanTimeKey;
static char kXNFScrollLockAppliedKey;
static char kXNFLastDeferredEnforcementTimeKey;
static char kXNFLastLayoutEnforcementTimeKey;

static const CFTimeInterval kXNFPagingRescanInterval = 1.0;
static const CFTimeInterval kXNFDeferredEnforcementThrottle = 1.5;
static const CFTimeInterval kXNFLayoutEnforcementThrottle = 0.12;

// Helper function to check if current view controller is homepage timeline container
static inline BOOL isHomeTimelineContainer(UIViewController *vc) {
    if (!vc) {
        return NO;
    }

    static Class homeTimelineContainerClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        homeTimelineContainerClass = NSClassFromString(@"THFHomeTimelineContainerViewController");
    });

    if (!homeTimelineContainerClass) {
        return NO;
    }

    UIViewController *parent = vc.parentViewController;
    return parent ? [parent isKindOfClass:homeTimelineContainerClass] : NO;
}

static inline void ensureFollowingTabSelected(TFNScrollingSegmentedViewController *controller) {
    if (!controller) return;
    if ([controller selectedIndex] != 1) {
        [controller setSelectedIndex:1];
    }
}

static BOOL shouldScheduleDeferredEnforcement(TFNScrollingSegmentedViewController *controller) {
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRun = objc_getAssociatedObject(controller, &kXNFLastDeferredEnforcementTimeKey);
    if (lastRun && (now - lastRun.doubleValue) < kXNFDeferredEnforcementThrottle) {
        return NO;
    }

    objc_setAssociatedObject(controller, &kXNFLastDeferredEnforcementTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL shouldApplyLayoutEnforcement(TFNScrollingSegmentedViewController *controller) {
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRun = objc_getAssociatedObject(controller, &kXNFLastLayoutEnforcementTimeKey);
    if (lastRun && (now - lastRun.doubleValue) < kXNFLayoutEnforcementThrottle) {
        return NO;
    }

    objc_setAssociatedObject(controller, &kXNFLastLayoutEnforcementTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Helper function to refresh layout after a delay on main thread
static void refreshLayoutAfterDelay(UIView *view, NSTimeInterval delaySeconds) {
    if (!view) return;

    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongView = weakView;
        if (!strongView || !strongView.window) return;

        [strongView setNeedsLayout];
        [strongView layoutIfNeeded];
    });
}

// Check if scroll view is used for horizontal paging (ForYou/Following swipe)
static BOOL isLikelyHorizontalPagingScrollView(UIScrollView *scrollView) {
    if (!scrollView) return NO;

    CGRect bounds = scrollView.bounds;
    CGSize contentSize = scrollView.contentSize;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    if (width <= 0.0f || height <= 0.0f) return NO;

    // Primary indicator for explicit page containers.
    if (scrollView.pagingEnabled) return YES;

    BOOL hasHorizontalPages = contentSize.width >= width * 1.8f;
    BOOL hasMinimalVerticalTravel = contentSize.height <= height * 1.2f;
    if (hasHorizontalPages && hasMinimalVerticalTravel) return YES;

    if (scrollView.alwaysBounceHorizontal && !scrollView.alwaysBounceVertical && hasHorizontalPages) {
        return YES;
    }

    return NO;
}

static void collectPagedScrollViewsInView(UIView *view, NSMutableArray<UIScrollView *> *bucket) {
    if (!view) return;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        if ([candidate isKindOfClass:[UIScrollView class]]) {
            UIScrollView *scrollView = (UIScrollView *)candidate;
            if (isLikelyHorizontalPagingScrollView(scrollView)) {
                [bucket addObject:scrollView];
                continue;
            }
        }

        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }
}

static NSHashTable<UIScrollView *> *cachedPagingScrollViewsForRoot(UIView *rootView) {
    NSHashTable<UIScrollView *> *cache = objc_getAssociatedObject(rootView, &kXNFPagedScrollViewsKey);
    if (!cache) {
        cache = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(rootView, &kXNFPagedScrollViewsKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return cache;
}

static NSArray<UIScrollView *> *resolvePagedScrollViewsForRoot(UIView *rootView) {
    NSHashTable<UIScrollView *> *cache = cachedPagingScrollViewsForRoot(rootView);
    NSMutableArray<UIScrollView *> *activeCached = [NSMutableArray array];

    for (UIScrollView *scrollView in cache) {
        if (scrollView && [scrollView isDescendantOfView:rootView]) {
            [activeCached addObject:scrollView];
        }
    }

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRescanTime = objc_getAssociatedObject(rootView, &kXNFLastPagingRescanTimeKey);
    BOOL shouldRescan = !lastRescanTime || ((now - lastRescanTime.doubleValue) >= kXNFPagingRescanInterval);
    if (activeCached.count == 0) {
        shouldRescan = YES;
    }

    if (!shouldRescan) {
        return activeCached;
    }

    NSMutableArray<UIScrollView *> *detected = [NSMutableArray array];
    collectPagedScrollViewsInView(rootView, detected);
    for (UIScrollView *scrollView in detected) {
        [cache addObject:scrollView];
    }

    objc_setAssociatedObject(rootView, &kXNFLastPagingRescanTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return detected.count > 0 ? detected : activeCached;
}

static BOOL isScrollViewLockApplied(UIScrollView *scrollView) {
    return [objc_getAssociatedObject(scrollView, &kXNFScrollLockAppliedKey) boolValue];
}

static BOOL isScrollViewCurrentlyLocked(UIScrollView *scrollView) {
    return !scrollView.scrollEnabled && !scrollView.pagingEnabled && !scrollView.alwaysBounceHorizontal;
}

static void markScrollViewLockApplied(UIScrollView *scrollView) {
    objc_setAssociatedObject(scrollView, &kXNFScrollLockAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void disableHorizontalGesturesForViewAndAncestors(UIView *view, NSUInteger maxAncestorHops) {
    UIView *current = view;
    NSUInteger hopCount = 0;

    while (current && hopCount <= maxAncestorHops) {
        for (UIGestureRecognizer *gesture in current.gestureRecognizers) {
            if (!gesture.enabled) continue;

            if ([gesture isKindOfClass:[UISwipeGestureRecognizer class]]) {
                UISwipeGestureRecognizer *swipe = (UISwipeGestureRecognizer *)gesture;
                if (swipe.direction & (UISwipeGestureRecognizerDirectionLeft | UISwipeGestureRecognizerDirectionRight)) {
                    gesture.enabled = NO;
                }
            } else if ([gesture isKindOfClass:[UIPanGestureRecognizer class]] &&
                       ![gesture isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
                gesture.enabled = NO;
            }
        }

        current = current.superview;
        hopCount++;
    }
}

// Keep the paging scroll view anchored on the Following page (index 1) if available
static void lockScrollViewToFollowingPage(UIScrollView *scrollView) {
    if (!scrollView) return;

    CGFloat pageWidth = CGRectGetWidth(scrollView.bounds);
    if (pageWidth <= 0.0f) return;

    CGFloat maxOffsetX = MAX(0.0f, scrollView.contentSize.width - pageWidth);
    CGFloat targetOffsetX = MIN(maxOffsetX, pageWidth);

    CGPoint offset = scrollView.contentOffset;
    if (fabs(offset.x - targetOffsetX) > 0.5f) {
        offset.x = targetOffsetX;
        [scrollView setContentOffset:offset animated:NO];
    }
}

static void disableHorizontalScrollOnView(UIScrollView *scrollView) {
    if (!scrollView) return;

    lockScrollViewToFollowingPage(scrollView);
    if (isScrollViewLockApplied(scrollView) && isScrollViewCurrentlyLocked(scrollView)) {
        return;
    }

    // Disable all horizontal paging/swipe interaction.
    scrollView.pagingEnabled = NO;
    scrollView.alwaysBounceHorizontal = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.bounces = NO;
    scrollView.scrollEnabled = NO;

    UIPanGestureRecognizer *panGesture = scrollView.panGestureRecognizer;
    if (panGesture && panGesture.enabled) {
        panGesture.enabled = NO;
    }

    for (UIGestureRecognizer *gesture in scrollView.gestureRecognizers) {
        if (!gesture.enabled) continue;

        if ([gesture isKindOfClass:[UISwipeGestureRecognizer class]]) {
            gesture.enabled = NO;
        } else if ([gesture isKindOfClass:[UIPanGestureRecognizer class]] && gesture != panGesture) {
            gesture.enabled = NO;
        }
    }

    disableHorizontalGesturesForViewAndAncestors(scrollView, 2);
    markScrollViewLockApplied(scrollView);
}

static void applyPagingLockForRootView(UIView *rootView) {
    if (!rootView) return;

    for (UIScrollView *scrollView in resolvePagedScrollViewsForRoot(rootView)) {
        disableHorizontalScrollOnView(scrollView);
    }
}

static void applyHomeTimelinePagingLock(TFNScrollingSegmentedViewController *controller) {
    if (!controller || !controller.view) return;
    applyPagingLockForRootView(controller.view);
}

static void enforceHomeTimelineNoPaging(TFNScrollingSegmentedViewController *controller) {
    if (!controller || !controller.view) return;

    applyHomeTimelinePagingLock(controller);
    if (!shouldScheduleDeferredEnforcement(controller)) return;

    __weak TFNScrollingSegmentedViewController *weakController = controller;

    // Re-apply later to catch timeline subviews created after initial appearance.
    NSArray<NSNumber *> *delays = @[@(0.4), @(1.0), @(2.0)];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TFNScrollingSegmentedViewController *strongController = weakController;
            if (!strongController || !strongController.view) return;
            applyHomeTimelinePagingLock(strongController);
        });
    }
}

%hook TFNScrollingSegmentedViewController

// Hide tab bar labels only on homepage timeline container
- (BOOL)_tfn_shouldHideLabelBar {
    return isHomeTimelineContainer(self) ? YES : %orig;
}

// Ensure proper view loading and prevent white screen, only on homepage
- (void)viewDidLoad {
    %orig;

    if (isHomeTimelineContainer(self)) {
        ensureFollowingTabSelected(self);
    }
}

// Additional fix for view appearance to ensure content loads properly, only on homepage
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (isHomeTimelineContainer(self)) {
        ensureFollowingTabSelected(self);
        refreshLayoutAfterDelay(self.view, 0.1);
        enforceHomeTimelineNoPaging(self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;

    if (isHomeTimelineContainer(self) && shouldApplyLayoutEnforcement(self)) {
        applyHomeTimelinePagingLock(self);
    }
}

// Ensure selected index is always the Following tab, only on homepage
- (void)setSelectedIndex:(NSInteger)index {
    if (isHomeTimelineContainer(self)) {
        %orig(1); // Always set to Following tab (index 1)
    } else {
        %orig(index); // Use the original index for other interfaces
    }
}

%end

// Fix refresh functionality
%hook THFTimelineViewController

- (void)_pullToRefresh:(id)sender {
    %orig;
    refreshLayoutAfterDelay(self.view, 0.5);
}

%end
