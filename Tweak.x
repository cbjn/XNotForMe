#import <UIKit/UIKit.h>

@interface TFNScrollingSegmentedViewController : UIViewController
- (void)setSelectedIndex:(NSInteger)index;
- (NSInteger)selectedIndex;
@end

@interface THFTimelineViewController : UIViewController
- (void)_pullToRefresh:(id)sender;
@end

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

// Helper function to refresh layout after a delay on main thread
static void refreshLayoutAfterDelay(UIView *view, NSTimeInterval delaySeconds) {
    if (!view) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [view setNeedsLayout];
        [view layoutIfNeeded];
    });
}

// Check if scroll view is used for horizontal paging (ForYou/Following swipe)
static BOOL isLikelyHorizontalPagingScrollView(UIScrollView *scrollView) {
    if (!scrollView) return NO;
    
    // Primary check: paging enabled is the main indicator
    if (scrollView.pagingEnabled) return YES;
    
    CGRect bounds = scrollView.bounds;
    CGSize contentSize = scrollView.contentSize;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    
    if (width <= 0.0f || height <= 0.0f) return NO;
    
    // Check for horizontal scroll capability
    BOOL hasHorizontalContent = contentSize.width > width + 1.0f;
    BOOL hasMinimalVerticalScroll = contentSize.height <= height + 50.0f;
    
    // Horizontal-only scroll view with multiple pages
    if (hasHorizontalContent && hasMinimalVerticalScroll) {
        // Check if content width suggests multiple pages
        if (contentSize.width >= width * 1.5f) return YES;
    }
    
    // Check bounce settings suggesting horizontal scroll
    if (scrollView.alwaysBounceHorizontal && !scrollView.alwaysBounceVertical) return YES;
    
    return NO;
}

static void collectPagedScrollViewsInView(UIView *view, NSMutableArray<UIScrollView *> *bucket) {
    if (!view) return;

    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        if (isLikelyHorizontalPagingScrollView(scrollView)) {
            [bucket addObject:scrollView];
            return;
        }
    }

    for (UIView *subview in view.subviews) {
        collectPagedScrollViewsInView(subview, bucket);
    }
}

static void disableHorizontalGesturesForViewAndAncestors(UIView *view, NSUInteger maxAncestorHops) {
    UIView *current = view;
    NSUInteger hopCount = 0;

    while (current && hopCount <= maxAncestorHops) {
        for (UIGestureRecognizer *gesture in current.gestureRecognizers) {
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
    if (offset.x != targetOffsetX) {
        offset.x = targetOffsetX;
        [scrollView setContentOffset:offset animated:NO];
    }
}

static void disableHorizontalScrollOnView(UIScrollView *scrollView) {
    if (!scrollView) return;
    
    lockScrollViewToFollowingPage(scrollView);

    // Disable all horizontal paging/swipe interaction
    scrollView.pagingEnabled = NO;
    scrollView.alwaysBounceHorizontal = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.bounces = NO;
    scrollView.scrollEnabled = NO;

    UIPanGestureRecognizer *panGesture = scrollView.panGestureRecognizer;
    if (panGesture) {
        panGesture.enabled = NO;
    }

    for (UIGestureRecognizer *gesture in scrollView.gestureRecognizers) {
        if ([gesture isKindOfClass:[UISwipeGestureRecognizer class]]) {
            gesture.enabled = NO;
        } else if ([gesture isKindOfClass:[UIPanGestureRecognizer class]] && gesture != panGesture) {
            gesture.enabled = NO;
        }
    }

    disableHorizontalGesturesForViewAndAncestors(scrollView, 2);
}

static void setPagingScrollViewsEnabled(UIView *rootView, BOOL enabled) {
    if (!rootView) return;

    NSMutableArray<UIScrollView *> *pagedScrollViews = [NSMutableArray array];
    collectPagedScrollViewsInView(rootView, pagedScrollViews);

    for (UIScrollView *scrollView in pagedScrollViews) {
        if (!enabled) {
            disableHorizontalScrollOnView(scrollView);
        } else {
            // Re-enable if needed
            scrollView.scrollEnabled = YES;
            scrollView.bounces = YES;
            scrollView.pagingEnabled = YES;
            scrollView.alwaysBounceHorizontal = YES;
            scrollView.showsHorizontalScrollIndicator = YES;
            UIPanGestureRecognizer *panGesture = scrollView.panGestureRecognizer;
            if (panGesture) {
                panGesture.enabled = YES;
            }
            for (UIGestureRecognizer *gesture in scrollView.gestureRecognizers) {
                if ([gesture isKindOfClass:[UISwipeGestureRecognizer class]] || [gesture isKindOfClass:[UIPanGestureRecognizer class]]) {
                    gesture.enabled = YES;
                }
            }
        }
    }
}

static void applyHomeTimelinePagingLock(TFNScrollingSegmentedViewController *controller) {
    if (!controller || !controller.view) return;
    setPagingScrollViewsEnabled(controller.view, NO);
}

static void enforceHomeTimelineNoPaging(TFNScrollingSegmentedViewController *controller) {
    if (!controller || !controller.view) return;

    applyHomeTimelinePagingLock(controller);

    __weak TFNScrollingSegmentedViewController *weakController = controller;
    
    // Apply multiple times to catch any late-added paging scroll views
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
        [self setSelectedIndex:1];
    }
}

// Additional fix for view appearance to ensure content loads properly, only on homepage
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (isHomeTimelineContainer(self)) {
        [self setSelectedIndex:1];
        refreshLayoutAfterDelay(self.view, 0.1);
        enforceHomeTimelineNoPaging(self);
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
