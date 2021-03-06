import Foundation
import CoreData
import MGSwipeTableCell
import WordPressComAnalytics
import WordPress_AppbotX
import WordPressShared



/// The purpose of this class is to render the collection of Notifications, associated to the main
/// WordPress.com account.
///
/// Plus, we provide a simple mechanism to render the details for a specific Notification,
/// given its remote identifier.
///
class NotificationsViewController: UITableViewController {
    // MARK: - Properties

    /// TableHeader
    ///
    @IBOutlet var tableHeaderView: UIView!

    /// Filtering Segmented Control
    ///
    @IBOutlet var filtersSegmentedControl: UISegmentedControl!

    /// Ratings View
    ///
    @IBOutlet var ratingsView: ABXPromptView!

    /// Defines the Height of the Ratings View
    ///
    @IBOutlet var ratingsHeightConstraint: NSLayoutConstraint!

    /// TableView Handler: Our commander in chief!
    ///
    fileprivate var tableViewHandler: WPTableViewHandler!

    /// NoResults View
    ///
    fileprivate var noResultsView: WPNoResultsView!

    /// All of the data will be fetched during the FetchedResultsController init. Prevent overfetching
    ///
    fileprivate var lastReloadDate = Date()

    /// Indicates whether the view is required to reload results on viewWillAppear, or not
    ///
    fileprivate var needsReloadResults = false

    /// Notifications that must be deleted display an "Undo" button, which simply cancels the deletion task.
    ///
    fileprivate var notificationDeletionRequests: [NSManagedObjectID: NotificationDeletionRequest] = [:]

    /// Notifications being deleted are proactively filtered from the list.
    ///
    fileprivate var notificationIdsBeingDeleted = Set<NSManagedObjectID>()



    // MARK: - View Lifecycle

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        // Note: This class doesn't actually conform to restoration?
        // Swift 3 migration: Brent Nov. 28/16
        //restorationClass = NotificationsViewController.self

        startListeningToAccountNotifications()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupNavigationBar()
        setupConstraints()
        setupTableView()
        setupTableHeaderView()
        setupTableFooterView()
        setupTableHandler()
        setupRatingsView()
        setupRefreshControl()
        setupNoResultsView()
        setupFiltersSegmentedControl()

        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Manually deselect the selected row. This is required due to a bug in iOS7 / iOS8
        tableView.deselectSelectedRowWithAnimation(true)

        // While we're onscreen, please, update rows with animations
        tableViewHandler.updateRowAnimation = .fade

        // Tracking
        WPAnalytics.track(WPAnalyticsStat.openedNotificationsList)

        // Notifications
        startListeningToNotifications()
        resetApplicationBadge()
        updateLastSeenTime()

        // Refresh the UI
        reloadResultsControllerIfNeeded()
        showNoResultsViewIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showRatingViewIfApplicable()
        syncNewNotifications()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopListeningToNotifications()

        // If we're not onscreen, don't use row animations. Otherwise the fade animation might get animated incrementally
        tableViewHandler.updateRowAnimation = .none
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Note: We're assuming `tableViewHandler` might be nil. Weird case in which the view
        // hasn't loaded, yet, but the method is still executed.
        tableViewHandler?.clearCachedRowHeights()
    }


    // MARK: - UITableView Methods

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return NoteTableHeaderView.headerHeight
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let sectionInfo = tableViewHandler.resultsController.sections?[section] else {
            return nil
        }

        let headerView = NoteTableHeaderView()
        headerView.title = Notification.descriptionForSectionIdentifier(sectionInfo.name)
        headerView.separatorColor = tableView.separatorColor

        return headerView
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        // Make sure no SectionFooter is rendered
        return CGFloat.leastNormalMagnitude
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        // Make sure no SectionFooter is rendered
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = NoteTableViewCell.reuseIdentifier()
        guard let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath) as? NoteTableViewCell else {
            fatalError()
        }

        configureCell(cell, at: indexPath)

        return cell
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return Settings.estimatedRowHeight
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // Load the Subject + Snippet
        guard let note = tableViewHandler.resultsController.object(at: indexPath) as? Notification else {
            return CGFloat.leastNormalMagnitude
        }

        // Old School Height Calculation
        let subject = note.subjectBlock?.attributedSubjectText
        let snippet = note.snippetBlock?.attributedSnippetText

        return NoteTableViewCell.layoutHeightWithWidth(tableView.bounds.width, subject: subject, snippet: snippet)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // Failsafe: Make sure that the Notification (still) exists
        guard let note = tableViewHandler.resultsController.object(at: indexPath) as? Notification else {
            tableView.deselectSelectedRowWithAnimation(true)
            return
        }

        // Push the Details: Unless the note has a pending deletion!
        guard deletionRequestForNoteWithID(note.objectID) == nil else {
            return
        }

        showDetailsForNotification(note)
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let note = sender as? Notification else {
            return
        }

        guard let detailsViewController = segue.destination as? NotificationDetailsViewController else {
            return
        }

        detailsViewController.note = note
        detailsViewController.onDeletionRequestCallback = { request in
            self.showUndeleteForNoteWithID(note.objectID, request: request)
        }
    }
}



// MARK: - User Interface Initialization
//
private extension NotificationsViewController {
    func setupNavigationBar() {
        // Don't show 'Notifications' in the next-view back button
        navigationItem.backBarButtonItem = UIBarButtonItem(title: String(), style: .plain, target: nil, action: nil)
        navigationItem.title = NSLocalizedString("Notifications", comment: "Notifications View Controller title")
    }

    func setupConstraints() {
        precondition(ratingsHeightConstraint != nil)

        // Ratings is initially hidden!
        ratingsHeightConstraint.constant = 0
    }

    func setupTableView() {
        // Register the cells
        let nib = UINib(nibName: NoteTableViewCell.classNameWithoutNamespaces(), bundle: Bundle.main)
        tableView.register(nib, forCellReuseIdentifier: NoteTableViewCell.reuseIdentifier())

        // UITableView
        tableView.accessibilityIdentifier  = "Notifications Table"
        tableView.cellLayoutMarginsFollowReadableWidth = false
        WPStyleGuide.configureColors(for: view, andTableView: tableView)
    }

    func setupTableHeaderView() {
        precondition(tableHeaderView != nil)

        // Fix: Update the Frame manually: Autolayout doesn't really help us, when it comes to Table Headers
        let requiredSize        = tableHeaderView.systemLayoutSizeFitting(view.bounds.size)
        var headerFrame         = tableHeaderView.frame
        headerFrame.size.height = requiredSize.height

        tableHeaderView.frame  = headerFrame
        tableHeaderView.layoutIfNeeded()

        // Due to iOS awesomeness, unless we re-assign the tableHeaderView, iOS might never refresh the UI
        tableView.tableHeaderView = tableHeaderView
        tableView.setNeedsLayout()
    }

    func setupTableFooterView() {
        //  Fix: Hide the cellSeparators, when the table is empty
        tableView.tableFooterView = UIView()
    }

    func setupTableHandler() {
        let handler = WPTableViewHandler(tableView: tableView)
        handler.cacheRowHeights = true
        handler.delegate = self
        tableViewHandler = handler
    }

    func setupRatingsView() {
        precondition(ratingsView != nil)

        let ratingsFont = WPFontManager.systemRegularFont(ofSize: Ratings.fontSize)

        ratingsView.label.font = ratingsFont
        ratingsView.leftButton.titleLabel?.font = ratingsFont
        ratingsView.rightButton.titleLabel?.font = ratingsFont
        ratingsView.delegate = self
        ratingsView.alpha = WPAlphaZero
    }

    func setupRefreshControl() {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refresh), for: .valueChanged)
        refreshControl = control
    }

    func setupNoResultsView() {
        noResultsView = WPNoResultsView()
        noResultsView.delegate = self
    }

    func setupFiltersSegmentedControl() {
        precondition(filtersSegmentedControl != nil)

        for filter in Filter.allFilters {
            filtersSegmentedControl.setTitle(filter.title, forSegmentAt: filter.rawValue)
        }

        WPStyleGuide.Notifications.configureSegmentedControl(filtersSegmentedControl)
    }
}



// MARK: - Notifications
//
private extension NotificationsViewController {
    func startListeningToNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(applicationDidBecomeActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
        nc.addObserver(self, selector: #selector(notificationsWereUpdated), name: NSNotification.Name(rawValue: NotificationSyncMediatorDidUpdateNotifications), object: nil)
    }

    func startListeningToAccountNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(defaultAccountDidChange), name: NSNotification.Name.WPAccountDefaultWordPressComAccountChanged, object: nil)
    }

    func stopListeningToNotifications() {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
        nc.removeObserver(self, name: NSNotification.Name(rawValue: NotificationSyncMediatorDidUpdateNotifications), object: nil)
    }

    @objc func applicationDidBecomeActive(_ note: Foundation.Notification) {
        // Let's reset the badge, whenever the app comes back to FG, and this view was upfront!
        guard isViewLoaded == true && view.window != nil else {
            return
        }

        resetApplicationBadge()
        updateLastSeenTime()
        reloadResultsControllerIfNeeded()
    }

    @objc func defaultAccountDidChange(_ note: Foundation.Notification) {
        needsReloadResults = true
        resetNotifications()
        resetLastSeenTime()
        resetApplicationBadge()
        syncNewNotifications()
    }

    @objc func notificationsWereUpdated(_ note: Foundation.Notification) {
        // If we're onscreen, don't leave the badge updated behind
        guard UIApplication.shared.applicationState == .active else {
            return
        }

        resetApplicationBadge()
        updateLastSeenTime()
    }
}



// MARK: - Public Methods
//
extension NotificationsViewController {
    /// Pushes the Details for a given notificationID, immediately, if the notification is already available.
    /// Otherwise, will attempt to Sync the Notification. If this cannot be achieved before the timeout defined
    /// by `Syncing.pushMaxWait` kicks in, we'll just do nothing (in order not to disrupt the UX!).
    ///
    /// - Parameter notificationID: The ID of the Notification that should be rendered onscreen.
    ///
    func showDetailsForNotificationWithID(_ noteId: String) {
        if let note = loadNotificationWithID(noteId) {
            showDetailsForNotification(note)
            return
        }

        syncNotificationWithID(noteId, timeout: Syncing.pushMaxWait) { note in
            self.showDetailsForNotification(note)
        }
    }

    /// Pushes the details for a given Notification Instance.
    ///
    /// - Parameter note: The Notification that should be rendered.
    ///
    func showDetailsForNotification(_ note: Notification) {
        DDLogSwift.logInfo("Pushing Notification Details for: [\(note.notificationId)]")

        // Track
        let properties = [Stats.noteTypeKey: note.type ?? Stats.noteTypeUnknown]
        WPAnalytics.track(.openedNotificationDetails, withProperties: properties)

        // Failsafe: Don't push nested!
        if navigationController?.visibleViewController != self {
            _ = navigationController?.popViewController(animated: false)
        }

        // Mark as Read
        if note.read == false {
            let mediator = NotificationSyncMediator()
            mediator?.markAsRead(note)
        }

        // Display Details
        if let postID = note.metaPostID, let siteID = note.metaSiteID, note.kind == .Matcher {
            let readerViewController = ReaderDetailViewController.controllerWithPostID(postID, siteID: siteID)
            navigationController?.pushFullscreenViewController(readerViewController, animated: true)
            return
        }

        performSegue(withIdentifier: NotificationDetailsViewController.classNameWithoutNamespaces(), sender: note)
    }

    /// Will display an Undelete button on top of a given notification.
    /// On timeout, the destructive action (received via parameter) will be exeuted, and the notification
    /// will (supposedly) get deleted.
    ///
    /// -   Parameters:
    ///     -   noteObjectID: The Core Data ObjectID associated to a given notification.
    ///     -   request: A DeletionRequest Struct
    ///
    func showUndeleteForNoteWithID(_ noteObjectID: NSManagedObjectID, request: NotificationDeletionRequest) {
        // Mark this note as Pending Deletion and Reload
        notificationDeletionRequests[noteObjectID] = request
        reloadRowForNotificationWithID(noteObjectID)

        // Dispatch the Action block
        perform(#selector(deleteNoteWithID), with: noteObjectID, afterDelay: Syncing.undoTimeout)
    }
}


// MARK: - Notifications Deletion Mechanism
//
private extension NotificationsViewController {
    @objc func deleteNoteWithID(_ noteObjectID: NSManagedObjectID) {
        // Was the Deletion Cancelled?
        guard let request = deletionRequestForNoteWithID(noteObjectID) else {
            return
        }

        // Hide the Notification
        notificationIdsBeingDeleted.insert(noteObjectID)
        reloadResultsController()

        // Hit the Deletion Action
        request.action { success in
            self.notificationDeletionRequests.removeValue(forKey: noteObjectID)
            self.notificationIdsBeingDeleted.remove(noteObjectID)

            // Error: let's unhide the row
            if success == false {
                self.reloadResultsController()
            }
        }
    }

    func cancelDeletionRequestForNoteWithID(_ noteObjectID: NSManagedObjectID) {
        notificationDeletionRequests.removeValue(forKey: noteObjectID)
        reloadRowForNotificationWithID(noteObjectID)

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deleteNoteWithID), object: noteObjectID)
    }

    func deletionRequestForNoteWithID(_ noteObjectID: NSManagedObjectID) -> NotificationDeletionRequest? {
        return notificationDeletionRequests[noteObjectID]
    }
}



// MARK: - WPTableViewHandler Helpers
//
private extension NotificationsViewController {
    func reloadResultsControllerIfNeeded() {
        // NSFetchedResultsController groups notifications based on a transient property ("sectionIdentifier").
        // Simply calling reloadData doesn't make the FRC recalculate the sections.
        // For that reason, let's force a reload, only when 1 day has elapsed, and sections would have changed.
        //
        let daysElapsed = Calendar.current.daysElapsedSinceDate(lastReloadDate)
        guard daysElapsed != 0 || needsReloadResults else {
            return
        }

        reloadResultsController()
    }

    func reloadResultsController() {
        // Update the Predicate: We can't replace the previous fetchRequest, since it's readonly!
        let fetchRequest = tableViewHandler.resultsController.fetchRequest
        fetchRequest.predicate = predicateForSelectedFilters()

        /// Refetch + Reload
        tableViewHandler.clearCachedRowHeights()
        _ = try? tableViewHandler.resultsController.performFetch()
        tableView.reloadData()

        // Empty State?
        showNoResultsViewIfNeeded()

        // Don't overwork!
        lastReloadDate = Date()
        needsReloadResults = false
    }

    func reloadRowForNotificationWithID(_ noteObjectID: NSManagedObjectID) {
        do {
            let note = try mainContext.existingObject(with: noteObjectID)

            if let indexPath = tableViewHandler.resultsController.indexPath(forObject: note) {
                tableView.reloadRows(at: [indexPath], with: .fade)
            }
        } catch {
            DDLogSwift.logError("Error refreshing Notification Row \(error)")
        }
    }
}



// MARK: - UIRefreshControl Methods
//
extension NotificationsViewController {
    func refresh() {
        guard let mediator = NotificationSyncMediator() else {
            refreshControl?.endRefreshing()
            return
        }

        let start = Date()

        mediator.sync { _ in

            let delta = max(Syncing.minimumPullToRefreshDelay + start.timeIntervalSinceNow, 0)
            let delay = DispatchTime.now() + Double(Int64(delta * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)

            DispatchQueue.main.asyncAfter(deadline: delay) { _ in
                self.refreshControl?.endRefreshing()
            }
        }
    }
}



// MARK: - UISegmentedControl Methods
//
extension NotificationsViewController {
    func segmentedControlDidChange(_ sender: UISegmentedControl) {
        reloadResultsController()

        // It's a long way, to the top (if you wanna rock'n roll!)
        guard tableViewHandler.resultsController.fetchedObjects?.count != 0 else {
            return
        }

        let path = IndexPath(row: 0, section: 0)
        tableView.scrollToRow(at: path, at: .bottom, animated: true)
    }
}



// MARK: - WPTableViewHandlerDelegate Methods
//
extension NotificationsViewController: WPTableViewHandlerDelegate {
    func managedObjectContext() -> NSManagedObjectContext {
        return ContextManager.sharedInstance().mainContext
    }

    func fetchRequest() -> NSFetchRequest<NSFetchRequestResult> {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName())
        request.sortDescriptors = [NSSortDescriptor(key: Filter.sortKey, ascending: false)]
        request.predicate = predicateForSelectedFilters()

        return request
    }

    func predicateForSelectedFilters() -> NSPredicate {
        var format = "NOT (SELF IN %@)"
        if let filter = Filter(rawValue: filtersSegmentedControl.selectedSegmentIndex), let condition = filter.condition {
            format += " AND \(condition)"
        }

        return NSPredicate(format: format, Array(notificationIdsBeingDeleted))
    }

    func configureCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        // iOS 8 has a nice bug in which, randomly, the last cell per section was getting an extra separator.
        // For that reason, we draw our own separators.
        //
        guard let note = tableViewHandler.resultsController.object(at: indexPath) as? Notification else {
            return
        }

        guard let cell = cell as? NoteTableViewCell else {
            return
        }

        let deletionRequest         = deletionRequestForNoteWithID(note.objectID)
        let isLastRow               = tableViewHandler.resultsController.isLastIndexPathInSection(indexPath)

        cell.attributedSubject      = note.subjectBlock?.attributedSubjectText
        cell.attributedSnippet      = note.snippetBlock?.attributedSnippetText
        cell.read                   = note.read
        cell.noticon                = note.noticon
        cell.unapproved             = note.isUnapprovedComment
        cell.showsBottomSeparator   = !isLastRow
        cell.undeleteOverlayText    = deletionRequest?.kind.legendText
        cell.onUndelete             = { [weak self] in
            self?.cancelDeletionRequestForNoteWithID(note.objectID)
        }

        cell.downloadIconWithURL(note.iconURL)

        configureCellActions(cell, note: note)
    }

    func configureCellActions(_ cell: NoteTableViewCell, note: Notification) {
        // Let "Mark as Read" expand
        let leadingExpansionButton = 0

        // Don't expand "Trash"
        let trailingExpansionButton = -1

        if UIView.userInterfaceLayoutDirection(for: view.semanticContentAttribute) == .leftToRight {
            cell.leftButtons = leadingButtons(note: note)
            cell.leftExpansion.buttonIndex = leadingExpansionButton
            cell.rightButtons = trailingButtons(note: note)
            cell.rightExpansion.buttonIndex = trailingExpansionButton
        } else {
            cell.rightButtons = leadingButtons(note: note)
            cell.rightExpansion.buttonIndex = trailingExpansionButton
            cell.leftButtons = trailingButtons(note: note)
            cell.leftExpansion.buttonIndex = trailingExpansionButton
        }
    }

    func sectionNameKeyPath() -> String {
        return "sectionIdentifier"
    }

    func entityName() -> String {
        return Notification.classNameWithoutNamespaces()
    }

    func tableViewDidChangeContent(_ tableView: UITableView) {
        // Due to an UIKit bug, we need to draw our own separators (Issue #2845). Let's update the separator status
        // after a DB OP. This loop has been measured in the order of milliseconds (iPad Mini)
        //
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? NoteTableViewCell else {
                continue
            }

            let isLastRow = tableViewHandler.resultsController.isLastIndexPathInSection(indexPath)
            cell.showsBottomSeparator = !isLastRow
        }

        // Update NoResults View
        showNoResultsViewIfNeeded()
    }
}



// MARK: - Actions
//


private extension NotificationsViewController {
    func leadingButtons(note: Notification) -> [MGSwipeButton] {
        guard !note.read else {
            return []
        }

        return [
            MGSwipeButton(title: NSLocalizedString("Mark Read", comment: "Marks a notification as read"), backgroundColor: WPStyleGuide.greyDarken20(), callback: { _ in
                NotificationSyncMediator()?.markAsRead(note)
                return true
            })
        ]
    }

    func trailingButtons(note: Notification) -> [MGSwipeButton] {
        var rightButtons = [MGSwipeButton]()

        guard let block = note.blockGroupOfKind(.comment)?.blockOfKind(.comment) else {
            return []
        }

        // Comments: Trash
        if block.isActionEnabled(.Trash) {
            let trashButton = MGSwipeButton(title: NSLocalizedString("Trash", comment: "Trashes a comment"), backgroundColor: WPStyleGuide.errorRed(), callback: { [weak self] _ in
                let request = NotificationDeletionRequest(kind: .deletion, action: { [weak self] onCompletion in
                    self?.actionsService.deleteCommentWithBlock(block) { success in
                        onCompletion(success)
                    }
                })

                self?.showUndeleteForNoteWithID(note.objectID, request: request)
                return true
            })
            rightButtons.append(trashButton)
        }

        guard block.isActionEnabled(.Approve) else {
            return rightButtons
        }

        // Comments: Unapprove
        if block.isActionOn(.Approve) {
            let title = NSLocalizedString("Unapprove", comment: "Unapproves a Comment")

            let unapproveButton = MGSwipeButton(title: title, backgroundColor: WPStyleGuide.grey(), callback: { [weak self] _ in
                self?.actionsService.unapproveCommentWithBlock(block)
                return true
            })

            rightButtons.append(unapproveButton)

            // Comments: Approve
        } else {
            let title = NSLocalizedString("Approve", comment: "Approves a Comment")

            let approveButton = MGSwipeButton(title: title, backgroundColor: WPStyleGuide.wordPressBlue(), callback: { [weak self] _ in
                self?.actionsService.approveCommentWithBlock(block)
                return true
            })

            rightButtons.append(approveButton)
        }

        return rightButtons
    }
}



// MARK: - Filter Helpers
//
private extension NotificationsViewController {
    func showFiltersSegmentedControlIfApplicable() {
        guard tableHeaderView.alpha == WPAlphaZero && shouldDisplayFilters == true else {
            return
        }

        UIView.animate(withDuration: WPAnimationDurationDefault, animations: {
            self.tableHeaderView.alpha = WPAlphaFull
        })
    }

    func hideFiltersSegmentedControlIfApplicable() {
        if tableHeaderView.alpha == WPAlphaFull && shouldDisplayFilters == false {
            tableHeaderView.alpha = WPAlphaZero
        }
    }

    var shouldDisplayFilters: Bool {
        // Filters should only be hidden whenever there are no Notifications in the bucket (contrary to the FRC's
        // results, which are filtered by the active predicate!).
        //
        let helper = CoreDataHelper<Notification>(context: mainContext)
        return helper.countObjects() > 0
    }
}



// MARK: - NoResults Helpers
//
private extension NotificationsViewController {
    func showNoResultsViewIfNeeded() {
        // Remove + Show Filters, if needed
        guard shouldDisplayNoResultsView == true else {
            noResultsView.removeFromSuperview()
            showFiltersSegmentedControlIfApplicable()
            return
        }

        // Attach the view
        if noResultsView.superview == nil {
            tableView.addSubview(withFadeAnimation: noResultsView)
        }

        // Refresh its properties: The user may have signed into WordPress.com
        noResultsView.titleText     = noResultsTitleText
        noResultsView.messageText   = noResultsMessageText
        noResultsView.accessoryView = noResultsAccessoryView
        noResultsView.buttonTitle   = noResultsButtonText

        // Hide the filter header if we're showing the Jetpack prompt
        hideFiltersSegmentedControlIfApplicable()
    }

    var noResultsTitleText: String {
        guard shouldDisplayJetpackMessage == false else {
            return NSLocalizedString("Connect to Jetpack", comment: "Notifications title displayed when a self-hosted user is not connected to Jetpack")
        }

        let messageMap: [Filter: String] = [
            .none: NSLocalizedString("No notifications yet", comment: "Displayed in the Notifications Tab, when there are no notifications"),
            .unread: NSLocalizedString("No unread notifications", comment: "Displayed in the Notifications Tab, when the Unread Filter shows no notifications"),
            .comment: NSLocalizedString("No comments notifications", comment: "Displayed in the Notifications Tab, when the Comments Filter shows no notifications"),
            .follow: NSLocalizedString("No new followers notifications", comment: "Displayed in the Notifications Tab, when the Follow Filter shows no notifications"),
            .like: NSLocalizedString("No like notifications", comment: "Displayed in the Notifications Tab, when the Likes Filter shows no notifications")
        ]

        let filter = Filter(rawValue: filtersSegmentedControl.selectedSegmentIndex) ?? .none
        return messageMap[filter] ?? String()
    }

    var noResultsMessageText: String? {
        let jetpackMessage = NSLocalizedString("Jetpack supercharges your self-hosted WordPress site.", comment: "Notifications message displayed when a self-hosted user is not connected to Jetpack")
        return shouldDisplayJetpackMessage ? jetpackMessage : nil
    }

    var noResultsAccessoryView: UIView? {
        return shouldDisplayJetpackMessage ? UIImageView(image: UIImage(named: "icon-jetpack-gray")) : nil
    }

    var noResultsButtonText: String? {
        return shouldDisplayJetpackMessage ? NSLocalizedString("Learn more", comment: "") : nil
    }

    var shouldDisplayJetpackMessage: Bool {
        return AccountHelper.isDotcomAvailable() == false
    }

    var shouldDisplayNoResultsView: Bool {
        return tableViewHandler.resultsController.fetchedObjects?.count == 0
    }
}


// MARK: - WPNoResultsViewDelegate Methods
//
extension NotificationsViewController: WPNoResultsViewDelegate {
    func didTap(_ noResultsView: WPNoResultsView) {
        guard let targetURL = URL(string: WPJetpackInformationURL) else {
            fatalError()
        }

        let webViewController = WPWebViewController(url: targetURL)
        let navController = UINavigationController(rootViewController: webViewController!)
        present(navController, animated: true, completion: nil)

        let properties = [Stats.sourceKey: Stats.sourceValue]
        WPAnalytics.track(.selectedLearnMoreInConnectToJetpackScreen, withProperties: properties)
    }
}


// MARK: - RatingsView Helpers
//
private extension NotificationsViewController {
    func showRatingViewIfApplicable() {
        guard AppRatingUtility.shared.shouldPromptForAppReview(section: Ratings.section) else {
            return
        }

        guard ratingsHeightConstraint.constant != Ratings.heightFull && ratingsView.alpha != WPAlphaFull else {
            return
        }

        ratingsView.alpha = WPAlphaZero

        UIView.animate(withDuration: WPAnimationDurationDefault, delay: Ratings.animationDelay, options: .curveEaseIn, animations: {
            self.ratingsView.alpha = WPAlphaFull
            self.ratingsHeightConstraint.constant = Ratings.heightFull

            self.setupTableHeaderView()
        }, completion: nil)

        WPAnalytics.track(.appReviewsSawPrompt)
    }

    func hideRatingView() {
        UIView.animate(withDuration: WPAnimationDurationDefault, animations: {
            self.ratingsView.alpha = WPAlphaZero
            self.ratingsHeightConstraint.constant = Ratings.heightZero

            self.setupTableHeaderView()
        })
    }
}


// MARK: - Sync'ing Helpers
//
private extension NotificationsViewController {
    func syncNewNotifications() {
        let mediator = NotificationSyncMediator()
        mediator?.sync()
    }

    func syncNotificationWithID(_ noteId: String, timeout: TimeInterval, success: @escaping (_ note: Notification) -> Void) {
        let mediator = NotificationSyncMediator()
        let startDate = Date()

        DDLogSwift.logInfo("Sync'ing Notification [\(noteId)]")

        mediator?.syncNote(with: noteId) { error, note in
            guard abs(startDate.timeIntervalSinceNow) <= timeout else {
                DDLogSwift.logError("Error: Timeout while trying to load Notification [\(noteId)]")
                return
            }

            guard let note = note else {
                DDLogSwift.logError("Error: Couldn't load Notification [\(noteId)]")
                return
            }

            DDLogSwift.logInfo("Notification Sync'ed in \(startDate.timeIntervalSinceNow) seconds")
            success(note)
        }
    }

    func updateLastSeenTime() {
        guard let note = tableViewHandler.resultsController.fetchedObjects?.first as? Notification else {
            return
        }

        guard let timestamp = note.timestamp, timestamp != lastSeenTime else {
            return
        }

        let mediator = NotificationSyncMediator()
        mediator?.updateLastSeen(timestamp) { error in
            guard error == nil else {
                return
            }

            self.lastSeenTime = timestamp
        }
    }

    func loadNotificationWithID(_ noteId: String) -> Notification? {
        let helper = CoreDataHelper<Notification>(context: mainContext)
        let predicate = NSPredicate(format: "(notificationId == %@)", noteId)

        return helper.firstObject(matchingPredicate: predicate)
    }

    func resetNotifications() {
        do {
            let helper = CoreDataHelper<Notification>(context: mainContext)
            helper.deleteAllObjects()
            try mainContext.save()
        } catch {
            DDLogSwift.logError("Error while trying to nuke Notifications Collection: [\(error)]")
        }
    }

    func resetLastSeenTime() {
        lastSeenTime = nil
    }

    func resetApplicationBadge() {
        UIApplication.shared.applicationIconBadgeNumber = 0
    }
}



// MARK: - ABXPromptViewDelegate Methods
//
extension NotificationsViewController: ABXPromptViewDelegate {
    func appbotPromptForReview() {
        WPAnalytics.track(.appReviewsRatedApp)
        AppRatingUtility.shared.ratedCurrentVersion()
        hideRatingView()

        UIApplication.shared.openURL(Ratings.reviewURL)
    }

    func appbotPromptForFeedback() {
        WPAnalytics.track(.appReviewsOpenedFeedbackScreen)
        ABXFeedbackViewController.show(from: self, placeholder: nil, delegate: nil)
        AppRatingUtility.shared.gaveFeedbackForCurrentVersion()
        hideRatingView()
    }

    func appbotPromptClose() {
        WPAnalytics.track(.appReviewsDeclinedToRateApp)
        AppRatingUtility.shared.declinedToRateCurrentVersion()
        hideRatingView()
    }

    func appbotPromptLiked() {
        WPAnalytics.track(.appReviewsLikedApp)
        AppRatingUtility.shared.likedCurrentVersion()
    }

    func appbotPromptDidntLike() {
        WPAnalytics.track(.appReviewsDidntLikeApp)
        AppRatingUtility.shared.dislikedCurrentVersion()
    }

    func abxFeedbackDidSendFeedback () {
        WPAnalytics.track(.appReviewsSentFeedback)
    }

    func abxFeedbackDidntSendFeedback() {
        WPAnalytics.track(.appReviewsCanceledFeedbackScreen)
    }
}



// MARK: - Private Properties
//
private extension NotificationsViewController {
    typealias NoteKind = Notification.Kind

    var mainContext: NSManagedObjectContext {
        return ContextManager.sharedInstance().mainContext
    }

    var actionsService: NotificationActionsService {
        return NotificationActionsService(managedObjectContext: mainContext)
    }

    var userDefaults: UserDefaults {
        return UserDefaults.standard
    }

    var lastSeenTime: String? {
        get {
            return userDefaults.string(forKey: Settings.lastSeenTime)
        }
        set {
            userDefaults.setValue(newValue, forKey: Settings.lastSeenTime)
            userDefaults.synchronize()
        }
    }

    enum Filter: Int {
        case none = 0
        case unread = 1
        case comment = 2
        case follow = 3
        case like = 4

        var condition: String? {
            switch self {
            case .none:     return nil
            case .unread:   return "read = NO"
            case .comment:  return "type = '\(NoteKind.Comment.toTypeValue)'"
            case .follow:   return "type = '\(NoteKind.Follow.toTypeValue)'"
            case .like:     return "type = '\(NoteKind.Like.toTypeValue)' OR type = '\(NoteKind.CommentLike.toTypeValue)'"
            }
        }

        var title: String {
            switch self {
            case .none:     return NSLocalizedString("All", comment: "Displays all of the Notifications, unfiltered")
            case .unread:   return NSLocalizedString("Unread", comment: "Filters Unread Notifications")
            case .comment:  return NSLocalizedString("Comments", comment: "Filters Comments Notifications")
            case .follow:   return NSLocalizedString("Follows", comment: "Filters Follows Notifications")
            case .like:     return NSLocalizedString("Likes", comment: "Filters Likes Notifications")
            }
        }

        static let sortKey = "timestamp"
        static let allFilters = [Filter.none, .unread, .comment, .follow, .like]
    }

    enum Settings {
        static let estimatedRowHeight = CGFloat(70)
        static let lastSeenTime = "notifications_last_seen_time"
    }

    enum Stats {
        static let networkStatusKey = "network_status"
        static let noteTypeKey = "notification_type"
        static let noteTypeUnknown = "unknown"
        static let sourceKey = "source"
        static let sourceValue = "notifications"
    }

    enum Syncing {
        static let minimumPullToRefreshDelay = TimeInterval(1.5)
        static let pushMaxWait = TimeInterval(1.5)
        static let syncTimeout = TimeInterval(10)
        static let undoTimeout = TimeInterval(4)
    }

    enum Ratings {
        static let section = "notifications"
        static let heightFull = CGFloat(100)
        static let heightZero = CGFloat(0)
        static let animationDelay = TimeInterval(0.5)
        static let fontSize = CGFloat(15.0)
        static let reviewURL = AppRatingUtility.shared.appReviewUrl
    }
}
