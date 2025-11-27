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

// Cached index path for "Following" tab to avoid repeated allocations
static inline NSIndexPath *followingTabIndexPath(void) {
    static NSIndexPath *cachedIndexPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedIndexPath = [NSIndexPath indexPathForRow:1 inSection:0];
    });
    return cachedIndexPath;
}

// Helper function to refresh layout after a delay on main thread
static void refreshLayoutAfterDelay(UIView *view, NSTimeInterval delaySeconds) {
    if (!view) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [view setNeedsLayout];
        [view layoutIfNeeded];
    });
}

static BOOL isLikelyHorizontalPagingScrollView(UIScrollView *scrollView) {
    if (!scrollView || !scrollView.pagingEnabled) {
        return NO;
    }

    CGRect bounds = scrollView.bounds;
    CGSize contentSize = scrollView.contentSize;

    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    if (width <= 0.0f || height <= 0.0f) {
        return NO;
    }

    CGFloat horizontalDelta = contentSize.width - width;
    CGFloat verticalDelta = contentSize.height - height;

    BOOL hasMeaningfulHorizontalContent = horizontalDelta > MAX(width * 0.1f, 24.0f);
    BOOL limitedVerticalExpansion = verticalDelta < MAX(height * 0.25f, 24.0f);

    if (!hasMeaningfulHorizontalContent) {
        if (scrollView.alwaysBounceHorizontal && !scrollView.alwaysBounceVertical) {
            hasMeaningfulHorizontalContent = YES;
        } else if (scrollView.contentOffset.x != 0.0f) {
            hasMeaningfulHorizontalContent = YES;
        } else if (scrollView.showsHorizontalScrollIndicator && !scrollView.showsVerticalScrollIndicator && horizontalDelta >= 0.0f) {
            hasMeaningfulHorizontalContent = YES;
        }
    }

    if (!hasMeaningfulHorizontalContent) {
        return NO;
    }

    if (limitedVerticalExpansion) {
        return YES;
    }

    if (contentSize.width > contentSize.height * 1.5f) {
        return YES;
    }

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

static void setPagingScrollViewsEnabled(UIView *rootView, BOOL enabled) {
    if (!rootView) return;

    NSMutableArray<UIScrollView *> *pagedScrollViews = [NSMutableArray array];
    collectPagedScrollViewsInView(rootView, pagedScrollViews);

    for (UIScrollView *scrollView in pagedScrollViews) {
        UIPanGestureRecognizer *panGesture = scrollView.panGestureRecognizer;
        BOOL panStateChanged = panGesture ? (panGesture.enabled != enabled) : NO;
        BOOL stateChanged = (scrollView.scrollEnabled != enabled) ||
                            panStateChanged ||
                            (scrollView.bounces != enabled);

        scrollView.scrollEnabled = enabled;
        if (panGesture) {
            panGesture.enabled = enabled;
        }
        scrollView.bounces = enabled;

        if (!enabled && (stateChanged || scrollView.contentOffset.x != 0.0f)) {
            CGPoint offset = scrollView.contentOffset;
            offset.x = 0.0f;
            [scrollView setContentOffset:offset animated:NO];
        }
    }
}

static void enforceHomeTimelineNoPaging(TFNScrollingSegmentedViewController *controller) {
    if (!controller) return;

    setPagingScrollViewsEnabled(controller.view, NO);

    __weak TFNScrollingSegmentedViewController *weakController = controller;
    const NSTimeInterval retryDelays[] = {0.15, 0.6, 1.2};
    NSUInteger delayCount = sizeof(retryDelays) / sizeof(NSTimeInterval);

    for (NSUInteger index = 0; index < delayCount; index++) {
        NSTimeInterval delay = retryDelays[index];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TFNScrollingSegmentedViewController *strongController = weakController;
            if (!strongController) return;
            setPagingScrollViewsEnabled(strongController.view, NO);
        });
    }
}

%hook TFNScrollingSegmentedViewController

// Hide tab bar labels only on homepage timeline container
- (BOOL)_tfn_shouldHideLabelBar {
    return isHomeTimelineContainer(self) ? YES : %orig;
}

// Always load "Following" tab content for homepage timeline container; otherwise default behavior.
- (UIViewController *)pagingViewController:(id)viewCtrl viewControllerAtIndexPath:(NSIndexPath *)indexPath {
    if (isHomeTimelineContainer(self)) {
        return %orig(viewCtrl, followingTabIndexPath());
    }

    return %orig(viewCtrl, indexPath);
}

// Ensure selected tab defaults to "Following" upon loading homepage timeline container.
- (void)viewDidLoad {
    %orig;

    if (isHomeTimelineContainer(self)) {
        if ([self selectedIndex] != 1) {
            [self setSelectedIndex:1]; // Set directly to Following tab at startup
        }
        enforceHomeTimelineNoPaging(self);
    } else {
        setPagingScrollViewsEnabled(self.view, YES);
    }
}

// Fix potential white screen issue by forcing layout update shortly after appearing.
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);

    if (isHomeTimelineContainer(self)) {
        if ([self selectedIndex] != 1) {
            [self setSelectedIndex:1];
        }
        refreshLayoutAfterDelay(self.view, 0.1); // Slight delay ensures proper rendering
        enforceHomeTimelineNoPaging(self);
    } else {
        setPagingScrollViewsEnabled(self.view, YES);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;

    if (isHomeTimelineContainer(self)) {
        setPagingScrollViewsEnabled(self.view, NO);
    } else {
        setPagingScrollViewsEnabled(self.view, YES);
    }
}

// Prevent changing away from "Following" tab when on homepage timeline container.
- (void)setSelectedIndex:(NSInteger)newIndex {
    BOOL isHome = isHomeTimelineContainer(self);
    NSInteger targetIndex = isHome ? 1 : newIndex;

    if (isHome && [self selectedIndex] == targetIndex) {
        return;
    }

    %orig(targetIndex);
}

%end

%hook THFTimelineViewController

// Fix pull-to-refresh functionality by ensuring proper layout updates afterward.
- (void)_pullToRefresh:(id)sender { 
   %orig(sender);
   refreshLayoutAfterDelay(self.view, 0.5); // Delay slightly longer for reliable UI update after refreshing data 
}

%end
