#import "PAAdminPanel.h"

#import "PAGrantService.h"
#import "PARuntimeBridge.h"
#import "PATrajectoryEngine.h"

NSString *const PAAdminPanelTrajectoryOptionsChangedNotification = @"PAAdminPanel.TrajectoryOptionsChanged";
NSString *const PAAdminPanelTrajectoryEnabledChangedNotification = @"PAAdminPanel.TrajectoryEnabledChanged";
NSString *const PAAdminPanelBallHighlightsChangedNotification    = @"PAAdminPanel.BallHighlightsChanged";

// ---------------------------------------------------------------------------
#pragma mark - Constants & Colors
// ---------------------------------------------------------------------------

static const CGFloat kToggleSize       = 46.0;
static const CGFloat kPanelWidth       = 330.0;
static const CGFloat kPanelHeight      = 490.0;
static const CGFloat kCornerRadius     = 16.0;
static const CGFloat kTabBarHeight     = 42.0;
static const CGFloat kPadding          = 12.0;

static UIColor *PATintColor(void)        { return [UIColor colorWithRed:0.18 green:0.55 blue:1.0 alpha:1.0]; }
static UIColor *PABackgroundColor(void)  { return [UIColor colorWithWhite:0.08 alpha:0.94]; }
static UIColor *PASurfaceColor(void)     { return [UIColor colorWithWhite:0.15 alpha:1.0]; }
static UIColor *PATextColor(void)        { return [UIColor colorWithWhite:0.96 alpha:1.0]; }
static UIColor *PASecondaryText(void)    { return [UIColor colorWithWhite:0.62 alpha:1.0]; }
static UIColor *PASuccessColor(void)     { return [UIColor colorWithRed:0.22 green:0.82 blue:0.40 alpha:1.0]; }
static UIColor *PADangerColor(void)      { return [UIColor colorWithRed:0.98 green:0.28 blue:0.28 alpha:1.0]; }
static UIColor *PAWarningColor(void)     { return [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:1.0]; }
static UIColor *PAPurpleColor(void)      { return [UIColor colorWithRed:0.65 green:0.35 blue:0.95 alpha:1.0]; }

static UIFont *PAFont(CGFloat size)      { return [UIFont systemFontOfSize:size weight:UIFontWeightMedium]; }
static UIFont *PABoldFont(CGFloat size)  { return [UIFont systemFontOfSize:size weight:UIFontWeightBold]; }
static UIFont *PAMonoFont(CGFloat size) {
    if (@available(iOS 13.0, *)) {
        return [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
    }
    return [UIFont fontWithName:@"Menlo-Regular" size:size] ?: [UIFont systemFontOfSize:size];
}

// ---------------------------------------------------------------------------
#pragma mark - Helpers
// ---------------------------------------------------------------------------

static UILabel *MakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static UIButton *MakeActionButton(NSString *title, UIColor *bgColor, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = PABoldFont(13);
    button.backgroundColor = bgColor;
    button.layer.cornerRadius = 8;
    button.clipsToBounds = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:36].active = YES;
    return button;
}

static UIView *MakeSeparator(void) {
    UIView *sep = [UIView new];
    sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return sep;
}

static UIView *MakeRowContainer(void) {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:38].active = YES;
    return row;
}

static NSString *FormatLargeNumber(uint64_t val) {
    if (val >= 1000000000ULL) return [NSString stringWithFormat:@"%.2fB", val / 1000000000.0];
    if (val >= 1000000ULL)    return [NSString stringWithFormat:@"%.2fM", val / 1000000.0];
    if (val >= 1000ULL)       return [NSString stringWithFormat:@"%.1fK", val / 1000.0];
    return [NSString stringWithFormat:@"%llu", val];
}

// ---------------------------------------------------------------------------
#pragma mark - PAToggleButton
// ---------------------------------------------------------------------------

@interface PAToggleButton : UIButton
@property(nonatomic) CGPoint touchStart;
@property(nonatomic) BOOL isDragging;
@property(nonatomic, strong, readonly) UIPanGestureRecognizer *panRecognizer;
@end

@implementation PAToggleButton {
    UIPanGestureRecognizer *_panRecognizer;
}

- (UIPanGestureRecognizer *)panRecognizer { return _panRecognizer; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = PATintColor();
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 3);
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowRadius = 6;
        self.clipsToBounds = NO;

        [self setTitle:@"🎱" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:22];

        _panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:_panRecognizer];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.touchStart = self.center;
        self.isDragging = YES;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.touchStart.x + translation.x, self.touchStart.y + translation.y);
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.isDragging = NO;
        CGFloat pad = 8.0;
        CGFloat midX = CGRectGetMidX(superview.bounds);
        CGFloat snapX = (self.center.x < midX) ? (self.bounds.size.width / 2.0 + pad)
                                               : (superview.bounds.size.width - self.bounds.size.width / 2.0 - pad);
        CGFloat minY = self.bounds.size.height / 2.0 + 40;
        CGFloat maxY = superview.bounds.size.height - self.bounds.size.height / 2.0 - 40;
        CGFloat snapY = MAX(minY, MIN(maxY, self.center.y));

        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.75
              initialSpringVelocity:0.8
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.center = CGPointMake(snapX, snapY); }
                         completion:nil];
    }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect expanded = CGRectInset(self.bounds, -10, -10);
    return CGRectContainsPoint(expanded, point);
}

@end

// ---------------------------------------------------------------------------
#pragma mark - PATabButton
// ---------------------------------------------------------------------------

@interface PATabButton : UIButton
@property(nonatomic) BOOL isActiveTab;
@end

@implementation PATabButton

- (void)setIsActiveTab:(BOOL)isActiveTab {
    _isActiveTab = isActiveTab;
    self.backgroundColor = isActiveTab ? PATintColor() : [UIColor clearColor];
    [self setTitleColor:isActiveTab ? UIColor.whiteColor : PASecondaryText() forState:UIControlStateNormal];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - PAAdminPanel
// ---------------------------------------------------------------------------

@interface PAAdminPanel () <UITextFieldDelegate>
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic, strong) PAToggleButton *toggleButton;
@property(nonatomic, strong) UIView *panelContainer;
@property(nonatomic, strong) UIVisualEffectView *blurView;

// Tabs
@property(nonatomic, strong) NSArray<PATabButton *> *tabButtons;
@property(nonatomic, strong) NSArray<UIScrollView *> *tabPages;
@property(nonatomic) NSInteger activeTabIndex;

// Trajectory state
@property(nonatomic, strong, readwrite) PATrajectoryOptions *trajectoryOptions;
@property(nonatomic, readwrite) BOOL trajectoryEnabled;
@property(nonatomic, readwrite) BOOL ballHighlightsEnabled;

// Grant tab controls
@property(nonatomic, strong) UITextField *customAmountField;
@property(nonatomic, strong) UILabel *grantStatusLabel;

// Info tab labels
@property(nonatomic, strong) UILabel *infoUserIdLabel;
@property(nonatomic, strong) UILabel *infoCoinsLabel;
@property(nonatomic, strong) UILabel *infoCashLabel;
@property(nonatomic, strong) UILabel *infoXPLabel;
@property(nonatomic, strong) UILabel *infoLevelLabel;
@property(nonatomic, strong) UILabel *infoOnlineLabel;
@property(nonatomic, strong) UILabel *infoInGameLabel;
@property(nonatomic, strong) UILabel *infoTurnLabel;
@property(nonatomic, strong) UITextView *auditTextView;

// Trajectory tab controls
@property(nonatomic, strong) UISlider *bouncesSlider;
@property(nonatomic, strong) UILabel  *bouncesValueLabel;
@property(nonatomic, strong) UISlider *depthSlider;
@property(nonatomic, strong) UILabel  *depthValueLabel;
@property(nonatomic, strong) UISlider *lengthSlider;
@property(nonatomic, strong) UILabel  *lengthValueLabel;
@property(nonatomic, strong) UISlider *spinXSlider;
@property(nonatomic, strong) UILabel  *spinXValueLabel;
@property(nonatomic, strong) UISlider *spinYSlider;
@property(nonatomic, strong) UILabel  *spinYValueLabel;

// Cheats tab controls
@property(nonatomic, strong) UILabel *cheatStatusLabel;
@property(nonatomic, strong) UISwitch *longGuidelinesSwitch;
@property(nonatomic, strong) UISwitch *hideNativeSwitch;
@property(nonatomic, strong) UISlider *powerSlider;
@property(nonatomic, strong) UILabel *powerValueLabel;

// Refresh timer
@property(nonatomic, strong) NSTimer *refreshTimer;
- (void)refreshPlayerInfoUnsafe;
@end

@implementation PAAdminPanel

+ (instancetype)shared {
    static PAAdminPanel *panel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ panel = [PAAdminPanel new]; });
    return panel;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _trajectoryOptions = [PATrajectoryOptions new];
        _trajectoryOptions.cushionBounces = 3;
        _trajectoryOptions.collisionDepth = 4;
        _trajectoryOptions.lengthMultiplier = 4.0;
        _trajectoryOptions.drawCueDeflection = YES;
        _trajectoryOptions.drawPocketAssist = YES;
        _trajectoryEnabled = YES;
        _ballHighlightsEnabled = YES;
        _activeTabIndex = 0;
    }
    return self;
}

// ---------------------------------------------------------------------------
#pragma mark - Public
// ---------------------------------------------------------------------------

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    // Must run on main thread — attach is called from window notifications.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachToWindow:window];
        });
        return;
    }
    // Idempotent re-attach (scene reconnect, new window): move existing
    // views instead of rebuilding (rebuilding leaks gestures/timers).
    if (self.toggleButton.superview == window && self.panelContainer.superview == window) {
        self.hostWindow = window;
        return;
    }
    if (self.toggleButton.superview && self.toggleButton.superview != window) {
        [self detach];
    }
    if (self.toggleButton.superview) return;
    self.hostWindow = window;

    // Toggle Button
    self.toggleButton = [[PAToggleButton alloc] initWithFrame:CGRectMake(0, 0, kToggleSize, kToggleSize)];
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = window.safeAreaInsets;
    self.toggleButton.center = CGPointMake(window.bounds.size.width - kToggleSize / 2.0 - safe.right - 10,
                                           safe.top + 130);
    // Keep the button above the trajectory overlay (which sits at back).
    self.toggleButton.layer.zPosition = 1000;
    // Tap-vs-drag disambiguation: a drag that moves the button must NEVER
    // open the panel. TouchUpInside can't tell them apart (it fires after a
    // drag), so the tap is a gesture that only fires when the pan fails.
    // Do NOT add a TouchUpInside target here.
    UITapGestureRecognizer *buttonTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    [buttonTap requireGestureRecognizerToFail:self.toggleButton.panRecognizer];
    [self.toggleButton addGestureRecognizer:buttonTap];
    [window addSubview:self.toggleButton];

    // Panel Container
    [self buildPanelInWindow:window];
    self.panelContainer.layer.zPosition = 999;

    // Auto-refresh timer
    if (!self.refreshTimer) {
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                             target:self
                                                           selector:@selector(autoRefresh)
                                                           userInfo:nil
                                                            repeats:YES];
    }
}

- (void)detach {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.toggleButton removeFromSuperview];
    [self.panelContainer removeFromSuperview];
    self.toggleButton = nil;
    self.panelContainer = nil;
}

- (void)setPanelVisible:(BOOL)panelVisible {
    if (panelVisible == self.isPanelVisible) return;
    self.panelContainer.hidden = !panelVisible;
    self.toggleButton.alpha = panelVisible ? 0.6 : 1.0;
    if (panelVisible) [self refreshPlayerInfo];
}

- (BOOL)isPanelVisible {
    return self.panelContainer && !self.panelContainer.hidden;
}

- (void)togglePanel {
    self.panelVisible = !self.isPanelVisible;
}

- (void)autoRefresh {
    if (self.isPanelVisible) {
        [self refreshPlayerInfo];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Build Panel
// ---------------------------------------------------------------------------

- (void)buildPanelInWindow:(UIWindow *)window {
    self.panelContainer = [UIView new];
    self.panelContainer.hidden = YES;
    self.panelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:self.panelContainer];

    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = window.safeAreaInsets;
    // Cap panel size so it fits iPhone SE / landscape (prevents
    // unsatisfiable-constraint warnings and off-screen panels).
    CGFloat maxW = window.bounds.size.width - 24;
    CGFloat maxH = window.bounds.size.height - safe.top - safe.bottom - 24;
    CGFloat useW = MIN(kPanelWidth, MAX(280, maxW));
    CGFloat useH = MIN(kPanelHeight, MAX(320, maxH));
    [NSLayoutConstraint activateConstraints:@[
        [self.panelContainer.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [self.panelContainer.topAnchor constraintEqualToAnchor:window.topAnchor constant:safe.top + 16],
        [self.panelContainer.widthAnchor constraintEqualToConstant:useW],
        [self.panelContainer.heightAnchor constraintEqualToConstant:useH],
    ]];

    // Blur
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
    self.blurView.layer.cornerRadius = kCornerRadius;
    self.blurView.clipsToBounds = YES;
    [self.panelContainer addSubview:self.blurView];
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.panelContainer.topAnchor],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.panelContainer.bottomAnchor],
    ]];

    // Background overlay
    UIView *bgOverlay = [UIView new];
    bgOverlay.backgroundColor = PABackgroundColor();
    bgOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    bgOverlay.layer.cornerRadius = kCornerRadius;
    bgOverlay.clipsToBounds = YES;
    [self.panelContainer addSubview:bgOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [bgOverlay.topAnchor constraintEqualToAnchor:self.panelContainer.topAnchor],
        [bgOverlay.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor],
        [bgOverlay.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor],
        [bgOverlay.bottomAnchor constraintEqualToAnchor:self.panelContainer.bottomAnchor],
    ]];

    // Title bar
    UIView *titleBar = [self buildTitleBar];
    [self.panelContainer addSubview:titleBar];
    [NSLayoutConstraint activateConstraints:@[
        [titleBar.topAnchor constraintEqualToAnchor:self.panelContainer.topAnchor],
        [titleBar.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor],
        [titleBar.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor],
        [titleBar.heightAnchor constraintEqualToConstant:38],
    ]];

    // Tab bar (4 tabs: Grants, Aim, Cheats, Info)
    UIView *tabBar = [self buildTabBar];
    [self.panelContainer addSubview:tabBar];
    [NSLayoutConstraint activateConstraints:@[
        [tabBar.topAnchor constraintEqualToAnchor:titleBar.bottomAnchor],
        [tabBar.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor constant:kPadding],
        [tabBar.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor constant:-kPadding],
        [tabBar.heightAnchor constraintEqualToConstant:kTabBarHeight],
    ]];

    // Pages
    UIScrollView *grantsPage     = [self buildGrantsPage];
    UIScrollView *aimPage        = [self buildTrajectoryPage];
    UIScrollView *cheatsPage     = [self buildCheatsPage];
    UIScrollView *infoPage       = [self buildInfoPage];
    self.tabPages = @[grantsPage, aimPage, cheatsPage, infoPage];

    for (UIScrollView *page in self.tabPages) {
        [self.panelContainer addSubview:page];
        [NSLayoutConstraint activateConstraints:@[
            [page.topAnchor constraintEqualToAnchor:tabBar.bottomAnchor constant:4],
            [page.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor],
            [page.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor],
            [page.bottomAnchor constraintEqualToAnchor:self.panelContainer.bottomAnchor],
        ]];
    }

    [self switchToTab:0];
}

- (UIView *)buildTitleBar {
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = MakeLabel(@"⚡ 8 Ball Pool Admin", PABoldFont(14), PATextColor());
    [bar addSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:PASecondaryText() forState:UIControlStateNormal];
    close.titleLabel.font = PAFont(18);
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [close.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [close.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:32],
        [close.heightAnchor constraintEqualToConstant:32],
    ]];

    UIView *sep = MakeSeparator();
    [bar addSubview:sep];
    [NSLayoutConstraint activateConstraints:@[
        [sep.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
    ]];

    return bar;
}

- (UIView *)buildTabBar {
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    bar.layer.cornerRadius = 8;
    bar.clipsToBounds = YES;

    NSArray *titles = @[@"Grants", @"Aim", @"Cheats", @"Info"];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        PATabButton *btn = [PATabButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = PAFont(12);
        btn.layer.cornerRadius = 6;
        btn.clipsToBounds = YES;
        btn.tag = (NSInteger)i;
        [btn addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:btn];
        [buttons addObject:btn];
    }
    self.tabButtons = buttons;

    [bar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor constant:3],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-3],
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:3],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-3],
    ]];

    return bar;
}

// ---------------------------------------------------------------------------
#pragma mark - Grants Tab
// ---------------------------------------------------------------------------

- (UIScrollView *)buildGrantsPage {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:kPadding],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:kPadding],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-kPadding],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-kPadding],
    ]];

    // Custom amount field
    UIView *amountRow = [UIView new];
    amountRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *amountLabel = MakeLabel(@"Amount:", PAFont(12), PASecondaryText());
    [amountRow addSubview:amountLabel];

    self.customAmountField = [UITextField new];
    self.customAmountField.placeholder = @"Custom (e.g. 500000)";
    self.customAmountField.font = PAMonoFont(12);
    self.customAmountField.textColor = PATextColor();
    self.customAmountField.backgroundColor = PASurfaceColor();
    self.customAmountField.layer.cornerRadius = 6;
    self.customAmountField.keyboardType = UIKeyboardTypeNumberPad;
    self.customAmountField.textAlignment = NSTextAlignmentCenter;
    self.customAmountField.delegate = self;
    self.customAmountField.translatesAutoresizingMaskIntoConstraints = NO;
    // Number pad has no return key — without this the keyboard traps all
    // touches (including game touches behind the panel).
    {
        UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
        UIBarButtonItem *flex =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                         target:nil action:nil];
        UIBarButtonItem *done =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                         target:self action:@selector(dismissKeyboard)];
        bar.items = @[flex, done];
        self.customAmountField.inputAccessoryView = bar;
    }
    [amountRow addSubview:self.customAmountField];

    [NSLayoutConstraint activateConstraints:@[
        [amountRow.heightAnchor constraintEqualToConstant:34],
        [amountLabel.leadingAnchor constraintEqualToAnchor:amountRow.leadingAnchor],
        [amountLabel.centerYAnchor constraintEqualToAnchor:amountRow.centerYAnchor],
        [amountLabel.widthAnchor constraintEqualToConstant:55],
        [self.customAmountField.leadingAnchor constraintEqualToAnchor:amountLabel.trailingAnchor constant:6],
        [self.customAmountField.trailingAnchor constraintEqualToAnchor:amountRow.trailingAnchor],
        [self.customAmountField.topAnchor constraintEqualToAnchor:amountRow.topAnchor],
        [self.customAmountField.bottomAnchor constraintEqualToAnchor:amountRow.bottomAnchor],
    ]];
    [stack addArrangedSubview:amountRow];

    // Currency Buttons
    [stack addArrangedSubview:MakeLabel(@"Currency", PABoldFont(11), PASecondaryText())];

    UIStackView *currencyRow = [[UIStackView alloc] init];
    currencyRow.axis = UILayoutConstraintAxisHorizontal;
    currencyRow.distribution = UIStackViewDistributionFillEqually;
    currencyRow.spacing = 6;
    currencyRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *coinsBtn = MakeActionButton(@"💰 Coins", PATintColor(), self, @selector(grantCoins));
    UIButton *cashBtn  = MakeActionButton(@"💎 Cash", PATintColor(), self, @selector(grantCash));
    UIButton *xpBtn    = MakeActionButton(@"⭐ XP", PATintColor(), self, @selector(grantXP));
    [currencyRow addArrangedSubview:coinsBtn];
    [currencyRow addArrangedSubview:cashBtn];
    [currencyRow addArrangedSubview:xpBtn];
    [stack addArrangedSubview:currencyRow];

    // VIP & Pool Points
    UIStackView *vipRow = [[UIStackView alloc] init];
    vipRow.axis = UILayoutConstraintAxisHorizontal;
    vipRow.distribution = UIStackViewDistributionFillEqually;
    vipRow.spacing = 6;
    vipRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *vipBtn   = MakeActionButton(@"👑 VIP Pts", PAPurpleColor(), self, @selector(grantVIP));
    UIButton *poolBtn  = MakeActionButton(@"🏆 Pool Pts", PAPurpleColor(), self, @selector(grantPoolPoints));
    [vipRow addArrangedSubview:vipBtn];
    [vipRow addArrangedSubview:poolBtn];
    [stack addArrangedSubview:vipRow];

    [stack addArrangedSubview:MakeSeparator()];

    // MAX EVERYTHING
    UIButton *maxBtn = MakeActionButton(@"🔥 MAX EVERYTHING 🔥", PADangerColor(), self, @selector(grantMaxEverything));
    [stack addArrangedSubview:maxBtn];

    // Quick Presets
    [stack addArrangedSubview:MakeLabel(@"Quick Bundles", PABoldFont(11), PASecondaryText())];

    NSArray *presets = PAGrantService.shared.presets;
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSDictionary *preset = presets[i];
        NSString *title = preset[@"title"] ?: @"Bundle";
        UIButton *btn = MakeActionButton(title, PASurfaceColor(), self, @selector(applyPreset:));
        btn.tag = (NSInteger)i;
        [btn setTitleColor:PATintColor() forState:UIControlStateNormal];
        [stack addArrangedSubview:btn];
    }

    [stack addArrangedSubview:MakeSeparator()];

    // Status label
    self.grantStatusLabel = MakeLabel(@"Ready", PAFont(11), PASuccessColor());
    self.grantStatusLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:self.grantStatusLabel];

    return scroll;
}

// ---------------------------------------------------------------------------
#pragma mark - Aim Tab
// ---------------------------------------------------------------------------

- (UIScrollView *)buildTrajectoryPage {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:kPadding],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:kPadding],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-kPadding],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-kPadding],
    ]];

    // Toggles
    [stack addArrangedSubview:[self buildToggleRow:@"🎯 Trajectory Overlay"
                                                on:self.trajectoryEnabled
                                            action:@selector(trajectoryToggled:)]];
    [stack addArrangedSubview:[self buildToggleRow:@"🎱 Ball ESP & Numbers"
                                                on:self.ballHighlightsEnabled
                                            action:@selector(highlightsToggled:)]];
    [stack addArrangedSubview:[self buildToggleRow:@"⚡ Cue Deflection"
                                                on:self.trajectoryOptions.drawCueDeflection
                                            action:@selector(deflectionToggled:)]];
    [stack addArrangedSubview:[self buildToggleRow:@"🕳️ Pocket Assist Guides"
                                                on:self.trajectoryOptions.drawPocketAssist
                                            action:@selector(pocketAssistToggled:)]];

    [stack addArrangedSubview:MakeSeparator()];

    // Sliders
    [stack addArrangedSubview:MakeLabel(@"Aim Physics Tuning", PABoldFont(11), PASecondaryText())];

    self.bouncesSlider = [self makeSliderMin:0 max:10 value:self.trajectoryOptions.cushionBounces action:@selector(bouncesChanged:)];
    self.bouncesValueLabel = MakeLabel([NSString stringWithFormat:@"%ld", (long)self.trajectoryOptions.cushionBounces], PAMonoFont(12), PATextColor());
    [stack addArrangedSubview:[self buildSliderRow:@"Cushion Bounces" slider:self.bouncesSlider valueLabel:self.bouncesValueLabel]];

    self.depthSlider = [self makeSliderMin:1 max:10 value:self.trajectoryOptions.collisionDepth action:@selector(depthChanged:)];
    self.depthValueLabel = MakeLabel([NSString stringWithFormat:@"%ld", (long)self.trajectoryOptions.collisionDepth], PAMonoFont(12), PATextColor());
    [stack addArrangedSubview:[self buildSliderRow:@"Ball Collision Depth" slider:self.depthSlider valueLabel:self.depthValueLabel]];

    self.lengthSlider = [self makeSliderMin:1 max:10 value:self.trajectoryOptions.lengthMultiplier action:@selector(lengthChanged:)];
    self.lengthValueLabel = MakeLabel([NSString stringWithFormat:@"%.1f", self.trajectoryOptions.lengthMultiplier], PAMonoFont(12), PATextColor());
    [stack addArrangedSubview:[self buildSliderRow:@"Line Length Multiplier" slider:self.lengthSlider valueLabel:self.lengthValueLabel]];

    [stack addArrangedSubview:MakeSeparator()];
    [stack addArrangedSubview:MakeLabel(@"Spin / English (Sidespin)", PABoldFont(11), PASecondaryText())];

    self.spinXSlider = [self makeSliderMin:-100 max:100 value:0 action:@selector(spinXChanged:)];
    self.spinXValueLabel = MakeLabel(@"0.00", PAMonoFont(12), PATextColor());
    [stack addArrangedSubview:[self buildSliderRow:@"Side Spin (X)" slider:self.spinXSlider valueLabel:self.spinXValueLabel]];

    self.spinYSlider = [self makeSliderMin:-100 max:100 value:0 action:@selector(spinYChanged:)];
    self.spinYValueLabel = MakeLabel(@"0.00", PAMonoFont(12), PATextColor());
    [stack addArrangedSubview:[self buildSliderRow:@"Top/Back Spin (Y)" slider:self.spinYSlider valueLabel:self.spinYValueLabel]];

    return scroll;
}

// ---------------------------------------------------------------------------
#pragma mark - Cheats Tab
// ---------------------------------------------------------------------------

- (UIScrollView *)buildCheatsPage {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:kPadding],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:kPadding],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-kPadding],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-kPadding],
    ]];

    // Active status banners
    UIView *statusBox = [UIView new];
    statusBox.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    statusBox.layer.cornerRadius = 8;
    statusBox.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:statusBox];

    UILabel *iapStatus = MakeLabel(@"🟢 Free StoreKit Purchases: ACTIVE", PAFont(11), PASuccessColor());
    UILabel *bypassStatus = MakeLabel(@"🟢 Sideload Anti-Tamper Bypass: ACTIVE", PAFont(11), PASuccessColor());
    [statusBox addSubview:iapStatus];
    [statusBox addSubview:bypassStatus];
    [NSLayoutConstraint activateConstraints:@[
        [statusBox.heightAnchor constraintEqualToConstant:48],
        [iapStatus.topAnchor constraintEqualToAnchor:statusBox.topAnchor constant:6],
        [iapStatus.leadingAnchor constraintEqualToAnchor:statusBox.leadingAnchor constant:8],
        [bypassStatus.bottomAnchor constraintEqualToAnchor:statusBox.bottomAnchor constant:-6],
        [bypassStatus.leadingAnchor constraintEqualToAnchor:statusBox.leadingAnchor constant:8],
    ]];

    [stack addArrangedSubview:MakeSeparator()];
    [stack addArrangedSubview:MakeLabel(@"Gameplay Hacks", PABoldFont(11), PASecondaryText())];

    // Infinite Guidelines
    UIButton *longGuideBtn = MakeActionButton(@"📏 Force Infinite Native Guidelines", PATintColor(), self, @selector(applyInfiniteGuidelines));
    [stack addArrangedSubview:longGuideBtn];

    // Hide Native Lines
    [stack addArrangedSubview:[self buildToggleRow:@"👁️ Hide Native Aim Guidelines"
                                                on:NO
                                            action:@selector(hideNativeGuidelinesToggled:)]];

    // Power Control
    [stack addArrangedSubview:MakeLabel(@"Shot Power Control", PABoldFont(11), PASecondaryText())];
    UIButton *maxPowerBtn = MakeActionButton(@"⚡ Max Shot Power (100%)", PAWarningColor(), self, @selector(applyMaxPower));
    [stack addArrangedSubview:maxPowerBtn];

    [stack addArrangedSubview:MakeSeparator()];
    [stack addArrangedSubview:MakeLabel(@"Special Unlockers", PABoldFont(11), PASecondaryText())];

    UIButton *cuesBtn = MakeActionButton(@"🔱 Unlock Popular Legendary Cues", PAPurpleColor(), self, @selector(unlockLegendaryCues));
    [stack addArrangedSubview:cuesBtn];

    UIButton *minigamesBtn = MakeActionButton(@"🎯 100x Golden & Lucky Shots", PASurfaceColor(), self, @selector(grantMinigamesMega));
    [minigamesBtn setTitleColor:PATintColor() forState:UIControlStateNormal];
    [stack addArrangedSubview:minigamesBtn];

    UIButton *passesBtn = MakeActionButton(@"🎟️ Season & Elite Pass Active", PASurfaceColor(), self, @selector(grantSeasonPasses));
    [passesBtn setTitleColor:PATintColor() forState:UIControlStateNormal];
    [stack addArrangedSubview:passesBtn];

    // Cheat status
    self.cheatStatusLabel = MakeLabel(@"Ready", PAFont(11), PASuccessColor());
    self.cheatStatusLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:self.cheatStatusLabel];

    return scroll;
}

// ---------------------------------------------------------------------------
#pragma mark - Info Tab
// ---------------------------------------------------------------------------

- (UIScrollView *)buildInfoPage {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:kPadding],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:kPadding],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-kPadding],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-kPadding],
    ]];

    [stack addArrangedSubview:MakeLabel(@"Live Account Summary", PABoldFont(11), PASecondaryText())];

    self.infoUserIdLabel = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoCoinsLabel  = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoCashLabel   = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoXPLabel     = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoLevelLabel  = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoOnlineLabel = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoInGameLabel = MakeLabel(@"—", PAMonoFont(12), PATextColor());
    self.infoTurnLabel   = MakeLabel(@"—", PAMonoFont(12), PATextColor());

    [stack addArrangedSubview:[self buildInfoRow:@"User ID"  valueLabel:self.infoUserIdLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"Coins"    valueLabel:self.infoCoinsLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"Cash"     valueLabel:self.infoCashLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"XP"       valueLabel:self.infoXPLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"Level"    valueLabel:self.infoLevelLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"Network"  valueLabel:self.infoOnlineLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"In Game"  valueLabel:self.infoInGameLabel]];
    [stack addArrangedSubview:[self buildInfoRow:@"My Turn"  valueLabel:self.infoTurnLabel]];

    UIButton *refreshBtn = MakeActionButton(@"🔄 Force Live Refresh", PASurfaceColor(), self, @selector(refreshPlayerInfo));
    [refreshBtn setTitleColor:PATintColor() forState:UIControlStateNormal];
    [stack addArrangedSubview:refreshBtn];

    [stack addArrangedSubview:MakeSeparator()];

    // Audit log
    [stack addArrangedSubview:MakeLabel(@"Audit Log (Recent Grants & IAPs)", PABoldFont(11), PASecondaryText())];

    self.auditTextView = [UITextView new];
    self.auditTextView.editable = NO;
    self.auditTextView.font = PAMonoFont(10);
    self.auditTextView.textColor = PASecondaryText();
    self.auditTextView.backgroundColor = PASurfaceColor();
    self.auditTextView.layer.cornerRadius = 6;
    self.auditTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.auditTextView.text = @"No events yet.";
    [stack addArrangedSubview:self.auditTextView];
    [NSLayoutConstraint activateConstraints:@[
        [self.auditTextView.heightAnchor constraintEqualToConstant:90],
    ]];

    UIButton *exportBtn = MakeActionButton(@"📋 Copy Audit JSON", PASurfaceColor(), self, @selector(copyAuditLog));
    [exportBtn setTitleColor:PATintColor() forState:UIControlStateNormal];
    [stack addArrangedSubview:exportBtn];

    return scroll;
}

// ---------------------------------------------------------------------------
#pragma mark - UI Row Builders
// ---------------------------------------------------------------------------

- (UIView *)buildToggleRow:(NSString *)title on:(BOOL)isOn action:(SEL)action {
    UIView *row = MakeRowContainer();

    UILabel *label = MakeLabel(title, PAFont(12), PATextColor());
    [row addSubview:label];

    UISwitch *toggle = [UISwitch new];
    toggle.on = isOn;
    toggle.onTintColor = PATintColor();
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:toggle];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    return row;
}

- (UIView *)buildSliderRow:(NSString *)title slider:(UISlider *)slider valueLabel:(UILabel *)valueLabel {
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = MakeLabel(title, PAFont(11), PASecondaryText());
    [container addSubview:label];
    [container addSubview:slider];
    [container addSubview:valueLabel];

    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:48],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [valueLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [valueLabel.widthAnchor constraintEqualToConstant:45],
        [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:2],
        [slider.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [slider.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];

    return container;
}

- (UISlider *)makeSliderMin:(float)min max:(float)max value:(float)value action:(SEL)action {
    UISlider *slider = [UISlider new];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = value;
    slider.minimumTrackTintColor = PATintColor();
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return slider;
}

- (UIView *)buildInfoRow:(NSString *)title valueLabel:(UILabel *)valueLabel {
    UIView *row = MakeRowContainer();
    [row.heightAnchor constraintEqualToConstant:24].active = YES;

    UILabel *label = MakeLabel(title, PAFont(11), PASecondaryText());
    [row addSubview:label];
    [row addSubview:valueLabel];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.widthAnchor constraintEqualToConstant:75],
        [valueLabel.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    return row;
}

// ---------------------------------------------------------------------------
#pragma mark - Tab Switching
// ---------------------------------------------------------------------------

- (void)tabTapped:(PATabButton *)sender {
    [self switchToTab:sender.tag];
}

- (void)switchToTab:(NSInteger)index {
    self.activeTabIndex = index;
    for (NSUInteger i = 0; i < self.tabButtons.count; i++) {
        self.tabButtons[i].isActiveTab = ((NSInteger)i == index);
        self.tabPages[i].hidden = ((NSInteger)i != index);
    }
    if (index == 3) [self refreshPlayerInfo];
}

// ---------------------------------------------------------------------------
#pragma mark - Grant Actions
// ---------------------------------------------------------------------------

- (uint64_t)currentAmount {
    NSString *text = self.customAmountField.text;
    uint64_t value = (uint64_t)[text longLongValue];
    return value > 0 ? value : 100000;
}

- (void)grantKind:(NSString *)kind amount:(uint64_t)amount productId:(NSString * _Nullable)productId {
    @try {
        NSMutableDictionary *grant = [@{ @"kind": kind, @"amount": @(amount) } mutableCopy];
        if (productId.length) grant[@"productId"] = productId;

        self.grantStatusLabel.text = [NSString stringWithFormat:@"Applying %@ …", kind];
        self.grantStatusLabel.textColor = PATintColor();

        [[PAGrantService shared] grantItems:@[grant] completion:^(BOOL success, NSString *message, NSDictionary *response) {
            @try {
                self.grantStatusLabel.text = message;
                self.grantStatusLabel.textColor = success ? PASuccessColor() : PADangerColor();
            } @catch (NSException *e) {}
        }];
    } @catch (NSException *e) {
        self.grantStatusLabel.text = @"Grant failed (exception)";
        self.grantStatusLabel.textColor = PADangerColor();
    }
}

- (void)grantCoins      { [self grantKind:@"coins"      amount:[self currentAmount] productId:nil]; }
- (void)grantCash       { [self grantKind:@"cash"        amount:[self currentAmount] productId:nil]; }
- (void)grantXP         { [self grantKind:@"xp"          amount:[self currentAmount] productId:nil]; }
- (void)grantVIP        { [self grantKind:@"vip_points"  amount:[self currentAmount] productId:nil]; }
- (void)grantPoolPoints { [self grantKind:@"pool_points" amount:[self currentAmount] productId:@"38156"]; }

- (void)grantMaxEverything {
    @try {
        [self grantMaxEverythingUnsafe];
    } @catch (NSException *e) {
        self.grantStatusLabel.text = @"MAX failed (exception)";
        self.grantStatusLabel.textColor = PADangerColor();
    }
}

- (void)grantMaxEverythingUnsafe {
    NSArray *grants = @[
        @{ @"kind": @"coins",       @"amount": @(999999999) },
        @{ @"kind": @"cash",        @"amount": @(999999) },
        @{ @"kind": @"xp",          @"amount": @(99999999) },
        @{ @"kind": @"vip_points",  @"amount": @(999999) },
        @{ @"kind": @"pool_points", @"amount": @(999999), @"productId": @"38156" },
        @{ @"kind": @"golden_shot", @"amount": @(100),    @"productId": @"golden_shot" },
        @{ @"kind": @"lucky_shot",  @"amount": @(100),    @"productId": @"lucky_shot" },
        @{ @"kind": @"spin",        @"amount": @(100),    @"productId": @"spin" },
        @{ @"kind": @"scratcher",   @"amount": @(100),    @"productId": @"scratcher" },
        @{ @"kind": @"season_pass", @"amount": @(1) },
        @{ @"kind": @"elite_pass",  @"amount": @(1) },
    ];

    self.grantStatusLabel.text = @"Applying MAX grants …";
    self.grantStatusLabel.textColor = PATintColor();

    [[PAGrantService shared] grantItems:grants completion:^(BOOL success, NSString *message, NSDictionary *response) {
        self.grantStatusLabel.text = success ? @"🔥 MAX applied successfully!" : message;
        self.grantStatusLabel.textColor = success ? PASuccessColor() : PADangerColor();
    }];
}

- (void)applyPreset:(UIButton *)sender {
    @try {
        NSArray *presets = PAGrantService.shared.presets;
        NSUInteger index = (NSUInteger)sender.tag;
        if (index >= presets.count) return;

        NSDictionary *preset = presets[index];
        NSArray *grants = preset[@"grants"];
        if (![grants isKindOfClass:NSArray.class]) return;

        NSString *title = preset[@"title"] ?: @"Preset";
        self.grantStatusLabel.text = [NSString stringWithFormat:@"Applying %@ …", title];
        self.grantStatusLabel.textColor = PATintColor();

        [[PAGrantService shared] grantItems:grants completion:^(BOOL success, NSString *message, NSDictionary *response) {
            @try {
                self.grantStatusLabel.text = success ? [NSString stringWithFormat:@"✅ %@ applied!", title] : message;
                self.grantStatusLabel.textColor = success ? PASuccessColor() : PADangerColor();
            } @catch (NSException *e) {}
        }];
    } @catch (NSException *e) {
        self.grantStatusLabel.text = @"Preset failed (exception)";
        self.grantStatusLabel.textColor = PADangerColor();
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Trajectory Actions
// ---------------------------------------------------------------------------

- (void)trajectoryToggled:(UISwitch *)sender {
    self.trajectoryEnabled = sender.isOn;
    [NSNotificationCenter.defaultCenter postNotificationName:PAAdminPanelTrajectoryEnabledChangedNotification object:self];
}

- (void)highlightsToggled:(UISwitch *)sender {
    self.ballHighlightsEnabled = sender.isOn;
    [PARuntimeBridge.shared setBallHighlightsEnabled:sender.isOn];
    [NSNotificationCenter.defaultCenter postNotificationName:PAAdminPanelBallHighlightsChangedNotification object:self];
}

- (void)deflectionToggled:(UISwitch *)sender {
    self.trajectoryOptions.drawCueDeflection = sender.isOn;
    [self postTrajectoryOptionsChanged];
}

- (void)pocketAssistToggled:(UISwitch *)sender {
    self.trajectoryOptions.drawPocketAssist = sender.isOn;
    [self postTrajectoryOptionsChanged];
}

- (void)bouncesChanged:(UISlider *)slider {
    NSInteger value = (NSInteger)roundf(slider.value);
    slider.value = value;
    self.trajectoryOptions.cushionBounces = value;
    self.bouncesValueLabel.text = [NSString stringWithFormat:@"%ld", (long)value];
    [self postTrajectoryOptionsChanged];
}

- (void)depthChanged:(UISlider *)slider {
    NSInteger value = (NSInteger)roundf(slider.value);
    slider.value = value;
    self.trajectoryOptions.collisionDepth = value;
    self.depthValueLabel.text = [NSString stringWithFormat:@"%ld", (long)value];
    [self postTrajectoryOptionsChanged];
}

- (void)lengthChanged:(UISlider *)slider {
    self.trajectoryOptions.lengthMultiplier = slider.value;
    self.lengthValueLabel.text = [NSString stringWithFormat:@"%.1f", slider.value];
    [self postTrajectoryOptionsChanged];
}

- (void)spinXChanged:(UISlider *)slider {
    double value = slider.value / 100.0;
    self.spinXValueLabel.text = [NSString stringWithFormat:@"%.2f", value];
    self.trajectoryOptions.spinX = value;
    [self postTrajectoryOptionsChanged];
}

- (void)spinYChanged:(UISlider *)slider {
    double value = slider.value / 100.0;
    self.spinYValueLabel.text = [NSString stringWithFormat:@"%.2f", value];
    self.trajectoryOptions.spinY = value;
    [self postTrajectoryOptionsChanged];
}

- (void)postTrajectoryOptionsChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:PAAdminPanelTrajectoryOptionsChangedNotification object:self];
}

// ---------------------------------------------------------------------------
#pragma mark - Cheats Actions
// ---------------------------------------------------------------------------

- (void)applyInfiniteGuidelines {
    @try {
        [PARuntimeBridge.shared setGuidelineLength:9999.0];
        self.cheatStatusLabel.text = @"📏 Infinite guideline set!";
        self.cheatStatusLabel.textColor = PASuccessColor();
    } @catch (NSException *e) {
        self.cheatStatusLabel.text = @"Failed (exception)";
        self.cheatStatusLabel.textColor = PADangerColor();
    }
}

- (void)hideNativeGuidelinesToggled:(UISwitch *)sender {
    @try {
        [PARuntimeBridge.shared setNativeGuidelinesHidden:sender.isOn];
        self.cheatStatusLabel.text = sender.isOn ? @"Native lines hidden" : @"Native lines visible";
        self.cheatStatusLabel.textColor = PATintColor();
    } @catch (NSException *e) {}
}

- (void)applyMaxPower {
    @try {
        [PARuntimeBridge.shared setPower:1.0];
        self.cheatStatusLabel.text = @"⚡ Max shot power applied!";
        self.cheatStatusLabel.textColor = PASuccessColor();
    } @catch (NSException *e) {
        self.cheatStatusLabel.text = @"Failed (exception)";
        self.cheatStatusLabel.textColor = PADangerColor();
    }
}

- (void)unlockLegendaryCues {
    NSArray *cues = @[
        @{@"kind": @"cue", @"productId": @"1001", @"amount": @1},
        @{@"kind": @"cue", @"productId": @"1002", @"amount": @1},
        @{@"kind": @"cue", @"productId": @"1003", @"amount": @1},
        @{@"kind": @"cue", @"productId": @"1004", @"amount": @1},
        @{@"kind": @"cue", @"productId": @"1005", @"amount": @1},
        @{@"kind": @"cue_pieces", @"productId": @"1001", @"amount": @100},
        @{@"kind": @"cue_pieces", @"productId": @"1002", @"amount": @100},
        @{@"kind": @"cue_pieces", @"productId": @"1003", @"amount": @100},
    ];
    [[PAGrantService shared] grantItems:cues completion:^(BOOL success, NSString *message, NSDictionary *response) {
        self.cheatStatusLabel.text = @"🔱 Legendary cues unlocked!";
        self.cheatStatusLabel.textColor = PASuccessColor();
    }];
}

- (void)grantMinigamesMega {
    NSArray *items = @[
        @{@"kind": @"golden_shot", @"productId": @"golden_shot", @"amount": @100},
        @{@"kind": @"lucky_shot",  @"productId": @"lucky_shot",  @"amount": @100},
        @{@"kind": @"spin",        @"productId": @"spin",        @"amount": @100},
        @{@"kind": @"scratcher",   @"productId": @"scratcher",   @"amount": @100},
    ];
    [[PAGrantService shared] grantItems:items completion:^(BOOL success, NSString *message, NSDictionary *response) {
        self.cheatStatusLabel.text = @"🎯 100x Minigames added!";
        self.cheatStatusLabel.textColor = PASuccessColor();
    }];
}

- (void)grantSeasonPasses {
    NSArray *passes = @[
        @{@"kind": @"season_pass",  @"amount": @1},
        @{@"kind": @"elite_pass",   @"amount": @1},
        @{@"kind": @"pool_points",  @"productId": @"38156", @"amount": @10000},
    ];
    [[PAGrantService shared] grantItems:passes completion:^(BOOL success, NSString *message, NSDictionary *response) {
        self.cheatStatusLabel.text = @"🎟️ Season passes activated!";
        self.cheatStatusLabel.textColor = PASuccessColor();
    }];
}

// ---------------------------------------------------------------------------
#pragma mark - Info Actions
// ---------------------------------------------------------------------------

- (void)refreshPlayerInfo {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshPlayerInfo];
        });
        return;
    }
    @try {
        [self refreshPlayerInfoUnsafe];
    } @catch (NSException *e) {
        NSLog(@"[PoolAdmin] refreshPlayerInfo exception: %@", e);
    }
}

- (void)refreshPlayerInfoUnsafe {
    NSDictionary *summary = [PARuntimeBridge.shared playerSummary];

    self.infoUserIdLabel.text = summary[@"userId"] ?: @"N/A";

    NSNumber *coins = summary[@"coins"];
    NSNumber *cash  = summary[@"cash"];
    NSNumber *xp    = summary[@"xp"];
    NSNumber *level = summary[@"level"];
    NSNumber *online = summary[@"online"];

    self.infoCoinsLabel.text  = coins ? FormatLargeNumber(coins.unsignedLongLongValue) : @"—";
    self.infoCashLabel.text   = cash  ? FormatLargeNumber(cash.unsignedLongLongValue) : @"—";
    self.infoXPLabel.text     = xp    ? FormatLargeNumber(xp.unsignedLongLongValue) : @"—";
    self.infoLevelLabel.text  = level ? [level stringValue] : @"—";

    if ([online boolValue]) {
        self.infoOnlineLabel.text = @"🟢 Online";
        self.infoOnlineLabel.textColor = PASuccessColor();
    } else {
        self.infoOnlineLabel.text = @"🔴 Offline";
        self.infoOnlineLabel.textColor = PADangerColor();
    }

    BOOL inGame = [PARuntimeBridge.shared isInGame];
    self.infoInGameLabel.text = inGame ? @"🟢 In Match" : @"⚪ In Menu";
    self.infoInGameLabel.textColor = inGame ? PASuccessColor() : PASecondaryText();

    BOOL myTurn = [PARuntimeBridge.shared isMyTurn];
    self.infoTurnLabel.text = myTurn ? @"⭐ YOUR TURN" : @"⏳ Opponent";
    self.infoTurnLabel.textColor = myTurn ? PAWarningColor() : PASecondaryText();

    // Audit log
    NSArray *events = [PAGrantService.shared recentAuditEvents];
    if (events.count == 0) {
        self.auditTextView.text = @"No events yet.";
    } else {
        NSMutableString *text = [NSMutableString string];
        NSUInteger start = events.count > 20 ? events.count - 20 : 0;
        for (NSUInteger i = events.count; i > start; i--) {
            NSDictionary *event = events[i - 1];
            NSString *timestamp = event[@"timestamp"] ?: @"";
            NSString *eventName = event[@"event"] ?: @"";
            NSRange timeRange = [timestamp rangeOfString:@"T"];
            if (timeRange.location != NSNotFound && timestamp.length > timeRange.location + 1) {
                timestamp = [timestamp substringFromIndex:timeRange.location + 1];
                if (timestamp.length > 8) timestamp = [timestamp substringToIndex:8];
            }
            [text appendFormat:@"[%@] %@\n", timestamp, eventName];
        }
        self.auditTextView.text = text;
    }
}

- (void)copyAuditLog {
    @try {
        NSString *json = [PAGrantService.shared exportAuditJSON];
        [UIPasteboard generalPasteboard].string = json;

        self.grantStatusLabel.text = @"📋 Audit log copied!";
        self.grantStatusLabel.textColor = PASuccessColor();
    } @catch (NSException *e) {
        self.grantStatusLabel.text = @"Copy failed";
        self.grantStatusLabel.textColor = PADangerColor();
    }
}

- (void)dismissKeyboard {
    @try {
        [self.customAmountField resignFirstResponder];
    } @catch (NSException *e) {}
}

// ---------------------------------------------------------------------------
#pragma mark - UITextFieldDelegate
// ---------------------------------------------------------------------------

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
