#import "WMFArticleContainerViewController.h"

// Frameworks
#import <Masonry/Masonry.h>
#import <BlocksKit/BlocksKit+UIKit.h>


// Controller
#import "WMFArticleViewController.h"
#import "WebViewController.h"
#import "UIViewController+WMFStoryboardUtilities.h"
#import "WMFSaveButtonController.h"
#import "WMFPreviewController.h"
#import "WMFArticleContainerViewController_Transitioning.h"
#import "WMFArticleHeaderImageGalleryViewController.h"
#import "WMFRelatedTitleListDataSource.h"
#import "WMFArticleListCollectionViewController.h"
#import "UITabBarController+WMFExtensions.h"

// Model
#import "MWKDataStore.h"
#import "MWKArticle+WMFAnalyticsLogging.h"
#import "MWKCitation.h"
#import "MWKTitle.h"
#import "MWKSavedPageList.h"
#import "MWKUserDataStore.h"

// Networking
#import "WMFArticleFetcher.h"

// View
#import "UIBarButtonItem+WMFButtonConvenience.h"
#import "UIScrollView+WMFContentOffsetUtils.h"
#import "UIWebView+WMFTrackingView.h"

NS_ASSUME_NONNULL_BEGIN

@interface WMFArticleContainerViewController ()
<WMFWebViewControllerDelegate,
 WMFArticleViewControllerDelegate,
 UINavigationControllerDelegate,
 WMFPreviewControllerDelegate>

@property (nonatomic, strong) MWKSavedPageList* savedPageList;
@property (nonatomic, strong) MWKDataStore* dataStore;

@property (nonatomic, strong) WebViewController* webViewController;
@property (nonatomic, strong) WMFArticleHeaderImageGalleryViewController* headerGallery;
@property (nonatomic, strong) WMFArticleListCollectionViewController* readMoreListViewController;

@property (nonatomic, strong) WMFArticleFetcher* articleFetcher;
@property (nonatomic, strong, nullable) WMFPreviewController* previewController;
@property (nonatomic, strong) WMFSaveButtonController* saveButtonController;

@property (nonatomic, strong) MASConstraint* headerHeightConstraint;

@end

@implementation WMFArticleContainerViewController
@synthesize article = _article;

#pragma mark - Setup

+ (instancetype)articleContainerViewControllerWithDataStore:(MWKDataStore*)dataStore
                                                 savedPages:(MWKSavedPageList*)savedPages {
    return [[self alloc] initWithDataStore:dataStore savedPages:savedPages];
}

- (instancetype)initWithDataStore:(MWKDataStore*)dataStore savedPages:(MWKSavedPageList*)savedPages {
    self = [super init];
    if (self) {
        self.savedPageList = savedPages;
        self.dataStore     = dataStore;
        // necessary to make sure tabbar/toolbar transitions happen when they're supposed to if this class is
        // instantiated programmatically
        self.hidesBottomBarWhenPushed = YES;
        [self setupToolbar];
    }
    return self;
}

- (instancetype __nullable)initWithCoder:(NSCoder*)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        // necessary to make sure tabbar/toolbar transitions happen when they're supposed to, if this class is
        // referenced in a storyboard
        self.hidesBottomBarWhenPushed = YES;
        [self setupToolbar];
    }
    return self;
}

#pragma mark - Accessors

- (NSString*)description {
    return [NSString stringWithFormat:@"%@ %@", [super description], self.article.title];
}

- (UIViewController<WMFArticleContentController>*)currentArticleController {
    return self.webViewController;
}

// TEMP: make immutable
- (void)setArticle:(MWKArticle* __nullable)article {
    if (WMF_EQUAL(_article, isEqualToArticle:, article)) {
        return;
    }

    if (self.article) {
        [self.articleFetcher cancelFetchForPageTitle:self.article.title];
    }

    _article = article;

    self.saveButtonController.title = article.title;

    if (self.isViewLoaded && (self.article.isCached || !self.article)) {
        self.webViewController.article = article;
        [self.headerGallery setImagesFromArticle:article];
    } else if (self.article) {
        [self fetchCurrentArticle];
    }
}

- (void)fetchCurrentArticle {
    @weakify(self);
    [self.articleFetcher fetchArticleForPageTitle:self.article.title progress:nil]
    .then(^(MWKArticle* article) {
        @strongify(self);
        self.article = article;
    });
}

- (WMFArticleListCollectionViewController*)readMoreListViewController {
    if (!_readMoreListViewController) {
        _readMoreListViewController             = [[WMFSelfSizingArticleListCollectionViewController alloc] init];
        _readMoreListViewController.recentPages = self.savedPageList.dataStore.userDataStore.historyList;
        _readMoreListViewController.dataStore   = self.savedPageList.dataStore;
        _readMoreListViewController.savedPages  = self.savedPageList;
        WMFRelatedTitleListDataSource* relatedTitlesDataSource =
            [[WMFRelatedTitleListDataSource alloc] initWithTitle:self.article.title
                                                       dataStore:self.savedPageList.dataStore
                                                   savedPageList:self.savedPageList
                                       numberOfExtractCharacters:200
                                                     resultLimit:3];
        // TODO: fetch lazily
        [relatedTitlesDataSource fetch];
        // TEMP: configure extract chars
        _readMoreListViewController.dataSource = relatedTitlesDataSource;
    }
    return _readMoreListViewController;
}

- (WMFArticleFetcher*)articleFetcher {
    if (!_articleFetcher) {
        _articleFetcher = [[WMFArticleFetcher alloc] initWithDataStore:self.dataStore];
    }
    return _articleFetcher;
}

- (WebViewController*)webViewController {
    if (!_webViewController) {
        _webViewController          = [WebViewController wmf_initialViewControllerFromClassStoryboard];
        _webViewController.delegate = self;
    }
    return _webViewController;
}

- (WMFArticleHeaderImageGalleryViewController*)headerGallery {
    if (!_headerGallery) {
        _headerGallery = [[WMFArticleHeaderImageGalleryViewController alloc] init];
        // TODO: add delegate callbacks for presenting full gallery
    }
    return _headerGallery;
}

// TEMP: delete!
- (WMFArticleViewController*)articleViewController {
    return nil;
}

#pragma mark - ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    [self addChildViewController:self.webViewController];
    [self.view addSubview:self.webViewController.view];
    [self.webViewController.view mas_makeConstraints:^(MASConstraintMaker* make) {
        make.leading.trailing.top.and.bottom.equalTo(self.view);
    }];
    [self.webViewController didMoveToParentViewController:self];

    /*
       NOTE: Need to add headers/footers as subviews as opposed to using contentInset, due to running into the following
       issues when attempting a contentInset approach:
       - doesn't work well for footers:
        - contentInset causes jumpiness when scrolling beyond _bottom_ of content
        - interferes w/ bouncing at the bottom
       - forces you to manually set scrollView insets
       - breaks native scrolling to top/bottom (i.e. title bar tap goes to top of content, not header)

       IOW, contentInset is nice for pull-to-refresh, parallax scrolling stuff, but not quite for table/collection-view-style
       headers & footers
     */

    [self addChildViewController:self.headerGallery];
    UIView* browserContainer = self.webViewController.webView.scrollView;
    [browserContainer addSubview:self.headerGallery.view];
    [self.headerGallery.view mas_makeConstraints:^(MASConstraintMaker* make) {
        make.leading.trailing.equalTo(self.view);
        make.top.equalTo(self.webViewController.webView.scrollView);
        self.headerHeightConstraint = make.height.equalTo(@([self headerHeightForCurrentTraitCollection]));
    }];
    [self.headerGallery didMoveToParentViewController:self];

    // TODO: lazily add & fetch readmore data when user is X points away from bottom of webview
    [self addChildViewController:self.readMoreListViewController];
    [browserContainer addSubview:self.readMoreListViewController.view];
    [self.readMoreListViewController.view mas_makeConstraints:^(MASConstraintMaker* make) {
        make.leading.trailing.equalTo(self.view);
        make.top.equalTo([self.webViewController.webView wmf_browserView].mas_bottom);
    }];

    // TODO: add logo & authorship footer

    [self.readMoreListViewController didMoveToParentViewController:self];

    if (self.article) {
        self.webViewController.article = self.article;
        [self.headerGallery setImagesFromArticle:self.article];
    }

    [self.KVOControllerNonRetaining observe:self.webViewController.webView.scrollView
                                    keyPath:WMF_SAFE_KEYPATH(self.webViewController.webView.scrollView, contentSize)
                                    options:0
                                      block:^(WMFArticleContainerViewController* observer, id object, NSDictionary* change) {
        [observer layoutWebViewSubviews];
    }];
}

- (CGFloat)headerHeightForCurrentTraitCollection {
    return [self headerHeightForTraitCollection:self.traitCollection];
}

- (CGFloat)headerHeightForTraitCollection:(UITraitCollection*)traitCollection {
    switch (traitCollection.verticalSizeClass) {
        case UIUserInterfaceSizeClassRegular:
            return 160;
        default:
            return 0;
    }
}

- (void)layoutWebViewSubviews {
    [self.headerHeightConstraint setOffset:[self headerHeightForCurrentTraitCollection]];
    CGFloat headerBottom = CGRectGetMaxY(self.headerGallery.view.frame);
    /*
       HAX: need to manage positioning the browser view manually.
       using constraints seems to prevent the browser view size and scrollview contentSize from being set
       properly.
     */
    UIView* browserView = [self.webViewController.webView wmf_browserView];
    [browserView setFrame:(CGRect){
         .origin = CGPointMake(0, headerBottom),
         .size = browserView.frame.size
     }];
    CGFloat readMoreHeight = self.readMoreListViewController.view.frame.size.height;
    CGFloat totalHeight    = CGRectGetMaxY(browserView.frame) + readMoreHeight;
    if (self.webViewController.webView.scrollView.contentSize.height != totalHeight) {
        self.webViewController.webView.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, totalHeight);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self layoutWebViewSubviews];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutWebViewSubviews];
}

- (UIBarItem*)paddingToolbarItem {
    UIBarButtonItem* item =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    item.width = 10.f;
    return item;
}

- (UIBarButtonItem*)saveToolbarItem {
    return [UIBarButtonItem wmf_buttonType:WMFButtonTypeBookmark handler:nil];
}

- (UIBarButtonItem*)refreshToolbarItem {
    return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                         target:self
                                                         action:@selector(didTapRefresh)];
}

- (UIBarButtonItem*)flexibleSpaceToolbarItem {
    return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                         target:nil
                                                         action:NULL];
}

- (UIBarButtonItem*)tableOfContentsToolbarItem {
    @weakify(self);
    UIBarButtonItem* item = [UIBarButtonItem wmf_buttonType:WMFButtonTypeTableOfContents handler:^(id sender){
        @strongify(self);
        [self.webViewController tocToggle];
    }];

    return item;
}

- (void)setupToolbar {
    UIBarButtonItem* saveToolbarItem = [self saveToolbarItem];
    self.toolbarItems = @[[self flexibleSpaceToolbarItem],
                          [self refreshToolbarItem],
                          [self paddingToolbarItem],
                          [self saveToolbarItem]];
    self.saveButtonController =
        [[WMFSaveButtonController alloc] initWithButton:(UIButton*)saveToolbarItem.customView
                                          savedPageList:self.savedPageList
                                                  title:self.article.title];

    if (!self.article.isMain) {
        self.navigationItem.rightBarButtonItem = [self tableOfContentsToolbarItem];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateInsetsForArticleViewController];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id < UIViewControllerTransitionCoordinatorContext > context) {
        [self updateInsetsForArticleViewController];
        [self.previewController updatePreviewWithSizeChange:size];
    } completion:NULL];
}

- (void)willTransitionToTraitCollection:(UITraitCollection*)newCollection withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super willTransitionToTraitCollection:newCollection withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id < UIViewControllerTransitionCoordinatorContext > _Nonnull context) {
        [self layoutWebViewSubviews];
    } completion:nil];
}

- (void)updateInsetsForArticleViewController {
    // TODO: remove
//    CGFloat topInset = [self.navigationController.navigationBar frame].size.height
//                       + [[UIApplication sharedApplication] statusBarFrame].size.height;
//
//    UIEdgeInsets adjustedInsets = UIEdgeInsetsMake(topInset,
//                                                   0.0,
//                                                   self.tabBarController.tabBar.frame.size.height,
//                                                   0.0);
//
//    self.articleViewController.tableView.contentInset          = adjustedInsets;
//    self.articleViewController.tableView.scrollIndicatorInsets = adjustedInsets;
//
//    //adjust offset if we are at the top
//    if (self.articleViewController.tableView.contentOffset.y <= 0) {
//        self.articleViewController.tableView.contentOffset = CGPointMake(0, -topInset);
//    }
}

#pragma mark - Toolbar Actions

- (void)didTapRefresh {
    [self fetchCurrentArticle];
}

#pragma mark - WebView Transition

- (void)showWebViewAnimated:(BOOL)animated {
//    [self.contentNavigationController pushViewController:self.webViewController animated:YES];
}

- (void)showWebViewAtFragment:(NSString*)fragment animated:(BOOL)animated {
    [self.webViewController scrollToFragment:fragment];
    [self showWebViewAnimated:animated];
}

#pragma mark - WMFArticleViewControllerDelegate

- (void)articleNavigator:(id<WMFArticleNavigation> __nullable)sender
      didTapCitationLink:(NSString* __nonnull)citationFragment {
    if (self.article.isCached) {
        [self showCitationWithFragment:citationFragment];
    } else {
        // TODO: fetch all sections before attempting to parse citations natively
//        if (!self.articleFetcherPromise) {
//            [self fetchArticle];
//        }
//        @weakify(self);
//        self.articleFetcherPromise.then(^(MWKArticle* _) {
//            @strongify(self);
//            [self showCitationWithFragment:citationFragment];
//        });
    }
}

- (void)articleViewController:(WMFArticleViewController* __nonnull)articleViewController
    didTapSectionWithFragment:(NSString* __nonnull)fragment {
    [self showWebViewAtFragment:fragment animated:YES];
}

- (void)showCitationWithFragment:(NSString*)fragment {
    // TODO: parse citations natively, then show citation popup control
//    NSParameterAssert(self.article.isCached);
//    MWKCitation* tappedCitation = [self.article.citations bk_match:^BOOL (MWKCitation* citation) {
//        return [citation.citationIdentifier isEqualToString:fragment];
//    }];
//    DDLogInfo(@"Tapped citation %@", tappedCitation);
//    if (!tappedCitation) {
//        DDLogWarn(@"Failed to parse citation for article %@", self.article);
//    }

    // TEMP: show webview until we figure out what to do w/ ReferencesVC
    [self showWebViewAtFragment:fragment animated:YES];
}

- (void)articleNavigator:(id<WMFArticleNavigation> __nullable)sender
        didTapLinkToPage:(MWKTitle* __nonnull)title {
    [self presentPopupForTitle:title];
}

- (void)articleNavigator:(id<WMFArticleNavigation> __nullable)sender
      didTapExternalLink:(NSURL* __nonnull)externalURL {
//    [[[SessionSingleton sharedInstance] zeroConfigState] showWarningIfNeededBeforeOpeningURL:externalURL];
}

#pragma mark - WMFArticleListItemController

- (WMFArticleControllerMode)mode {
    // TEMP: WebVC (and currentArticleController) will eventually conform to this
    return self.articleViewController.mode;
}

- (void)setMode:(WMFArticleControllerMode)mode animated:(BOOL)animated {
    // TEMP: WebVC (and currentArticleController) will eventually conform to this
    [self.articleViewController setMode:mode animated:animated];
}

#pragma mark - WMFWebViewControllerDelegate

- (void)webViewController:(WebViewController*)controller didTapOnLinkForTitle:(MWKTitle*)title {
    [self presentPopupForTitle:title];
}

#pragma mark - UINavigationControllerDelegate

- (void)navigationController:(UINavigationController*)navigationController willShowViewController:(UIViewController*)viewController animated:(BOOL)animated {
//    if (viewController == self.articleViewController) {
//        [self.navigationController setNavigationBarHidden:NO animated:NO];
//        [self.contentNavigationController setNavigationBarHidden:YES animated:NO];
//    } else {
//        [self.navigationController setNavigationBarHidden:YES animated:NO];
//        [self.contentNavigationController setNavigationBarHidden:NO animated:NO];
//    }
}

#pragma mark - Popup

- (void)presentPopupForTitle:(MWKTitle*)title {
    MWKArticle* article = [self.dataStore articleWithTitle:title];

    WMFArticleContainerViewController* vc =
        [[WMFArticleContainerViewController alloc] initWithDataStore:self.dataStore
                                                          savedPages:self.savedPageList];
    vc.article = article;

    //TODO: Disabling pop ups until Popup VC is redesigned.
    //Renable preview when this true

    [self.navigationController pushViewController:vc animated:YES];

    return;

    WMFPreviewController* previewController = [[WMFPreviewController alloc] initWithPreviewViewController:vc containingViewController:self tabBarController:self.navigationController.tabBarController];
    previewController.delegate = self;
    [previewController presentPreviewAnimated:YES];

    self.previewController = previewController;
}

#pragma mark - Analytics

- (NSString*)analyticsName {
    return [self.article analyticsName];
}

#pragma mark - WMFPreviewControllerDelegate

- (void)previewController:(WMFPreviewController*)previewController didPresentViewController:(UIViewController*)viewController {
    self.previewController = nil;

    /* HACK: for some reason, the view controller is unusable when it comes back from the preview.
     * Trying to display it causes much ballyhooing about constraints.
     * Work around, make another view controller and push it instead.
     */
    WMFArticleContainerViewController* previewed = (id)viewController;

    WMFArticleContainerViewController* vc =
        [[WMFArticleContainerViewController alloc] initWithDataStore:self.dataStore
                                                          savedPages:self.savedPageList];
    vc.article = previewed.article;
    [self.navigationController pushViewController:vc animated:NO];
}

- (void)previewController:(WMFPreviewController*)previewController didDismissViewController:(UIViewController*)viewController {
    self.previewController = nil;
}

@end

NS_ASSUME_NONNULL_END
