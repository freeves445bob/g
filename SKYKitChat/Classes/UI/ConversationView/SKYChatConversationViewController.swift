//
//  SKYChatConversationViewController.swift
//  SKYKitChat
//
//  Copyright 2016 Oursky Ltd.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import ALCameraViewController
import CTAssetsPickerController
import AVFoundation
import SKPhotoBrowser

@objc public protocol SKYChatConversationViewControllerDelegate: class {

    @objc optional func messagesFetchLimitInConversationViewController(
        _ controller: SKYChatConversationViewController) -> UInt

    /**
     * For customizing message date display
     */

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        dateStringAt indexPath: IndexPath) -> NSAttributedString

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        shouldShowDateAt indexPath: IndexPath) -> Bool

    /**
     * For customizing the views
     */

    @objc optional func incomingMessageColorForConversationViewController(
        _ controller: SKYChatConversationViewController) -> UIColor

    @objc optional func outgoingMessageColorForConversationViewController(
        _ controller: SKYChatConversationViewController) -> UIColor

    @objc optional func accessoryButtonShouldShowInConversationViewController(
        _ controller: SKYChatConversationViewController) -> Bool

    @objc optional func cameraButtonShouldShowInConversationViewController(
        _ controller: SKYChatConversationViewController) -> Bool

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        alertControllerForAccessoryButton button: UIButton) -> UIAlertController

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        shouldShowSenderNameAt indexPath: IndexPath) -> Bool

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        avatarForMessage message: SKYMessage,
        withAuthor author: SKYRecord?,
        atIndexPath indexPath: IndexPath) -> UIImage?

    /**
     * Hooks on send message flow
     */

    @objc optional func conversationViewController(_ controller: SKYChatConversationViewController,
                                                   readyToSendMessage message: SKYMessage)

    @objc optional func conversationViewController(_ controller: SKYChatConversationViewController,
                                                   finishSendingMessage message: SKYMessage)

    @objc optional func conversationViewController(_ controller: SKYChatConversationViewController,
                                                   failedToSendMessageText text: String,
                                                   date: Date,
                                                   error: Error)

    /**
     * Hooks on fetching participants / fetch message flow
     */

    @objc optional func conversationViewController(_ controller: SKYChatConversationViewController,
                                                   didFetchedParticipants participants: [SKYRecord])

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        failedFetchingParticipantWithError error: Error)

    @objc optional func startFetchingMessages(_ controller: SKYChatConversationViewController)

    @objc optional func conversationViewController(_ controller: SKYChatConversationViewController,
                                                   didFetchedMessages messages: [SKYMessage],
                                                   isCached isCached: Bool)

    @objc optional func conversationViewController(
        _ controller: SKYChatConversationViewController,
        failedFetchingMessagesWithError error: Error)
}

open class MessageList {

    public var messageIDs: NSMutableOrderedSet = NSMutableOrderedSet()
    public var messages: [String: SKYMessage] = [:]
    public var count: Int {
        get {
            return self.messages.count
        }
    }

    public func compare(messageA: SKYMessage, messageB: SKYMessage) -> Bool {
        return messageA.creationDate() < messageB.creationDate()
    }

    public func contains(_ messageID: String) -> Bool {
        return self.messageIDs.index(of: messageID) != NSNotFound
    }

    public func update(_ messages: [SKYMessage]) {
        messages.forEach { (msg: SKYMessage) in
            let msgID = msg.recordID().recordName
            self.messages[msgID] = msg
        }
    }

    public func append(_ messages: [SKYMessage]) {
        let msgs = Array(messages)
        let msgIDs = msgs.map { (msg: SKYMessage) -> String in
            return msg.recordID().recordName
        }

        self.messageIDs.addObjects(from: msgIDs)
        self.update(msgs)
    }

    public func merge(_ messages: [SKYMessage]) {
        self.append(messages)

        self.messageIDs = NSMutableOrderedSet(array: self.messageIDs
            .flatMap { $0 as? String }
            .sorted(by: { (id1: String, id2: String) -> Bool in
                let m1 = self.messages[id1]!
                let m2 = self.messages[id2]!
                return self.compare(messageA: m1, messageB: m2)
            }))
    }

    public func remove(_ messages: [SKYMessage]) {
        messages.forEach { (msg: SKYMessage) in
            let msgID = msg.recordID().recordName
            self.messageIDs.remove(msgID)
            self.messages.removeValue(forKey: msgID)
        }
    }

    public func removeAll() {
        self.messageIDs.removeAllObjects()
        self.messages.removeAll()
    }

    public func indexOf(_ message: SKYMessage) -> Int {
        return self.messageIDs.index(of: message.recordID().recordName)
    }

    public func messageAt(_ index: Int) -> SKYMessage {
        if let msgID = self.messageIDs[index] as? String {
            return self.messages[msgID]!
        }

        fatalError("messageIDs contains non String object")
    }

    public func firstSuccessMessage() -> SKYMessage? {
        for var messageID in self.messageIDs {
            if let id = messageID as? String {
                let message = self.messages[id]
                if let msg = message {
                    if !msg.fail {
                        return msg
                    }
                }
            }
        }

        return nil
    }

    public func first() -> SKYMessage {
        return self.messageAt(0)
    }

    public func last() -> SKYMessage {
        return self.messageAt(self.count - 1)
    }
}

open class SKYChatConversationViewController: JSQMessagesViewController, AVAudioRecorderDelegate, SKYChatConversationImageItemDelegate {

    weak public var delegate: SKYChatConversationViewControllerDelegate?

    public var skygear: SKYContainer = SKYContainer.default()
    public var conversation: SKYConversation?
    public var participants: [String: SKYRecord] = [:]
    public var messageList: MessageList = MessageList()
    public var typingIndicatorShowDuration: TimeInterval = TimeInterval(5)
    public var offsetYToLoadMore: CGFloat = CGFloat(400)
    fileprivate var hasMoreMessageToFetch: Bool = false
    fileprivate var isFetchingMessage: Bool = false

    public var messagesFetchLimit: UInt {
        get {
            if let limit = self.delegate?.messagesFetchLimitInConversationViewController?(self) {
                return limit
            }

            // default fetch limit
            return 50
        }
    }

    public var messageChangeObserver: Any?
    public var typingIndicatorChangeObserver: Any?
    public var typingIndicatorPromptTimer: Timer?

    public var bubbleFactory: JSQMessagesBubbleImageFactory? = JSQMessagesBubbleImageFactory()
    public var incomingMessageBubble: JSQMessagesBubbleImage?
    public var outgoingMessageBubble: JSQMessagesBubbleImage?

    let downloadDispatcher = SimpleDownloadDispatcher.default()
    public var dataCache: DataCache = MemoryDataCache.shared()
    public var assetCache: SKYAssetCache = SKYAssetMemoryCache.shared()
    public var messageMediaDataFactory = JSQMessageMediaDataFactory()

    public var cameraButton: UIButton?

    public var conversationView: SKYChatConversationView? {
        guard let view = self.collectionView as? SKYChatConversationView else {
            return nil
        }

        return view
    }

    public var incomingMessageBubbleColor: UIColor? {
        didSet {
            self.incomingMessageBubble = self.bubbleFactory?
                .incomingMessagesBubbleImage(with: self.incomingMessageBubbleColor)
        }
    }

    public var outgoingMessageBubbleColor: UIColor? {
        didSet {
            self.outgoingMessageBubble = self.bubbleFactory?
                .outgoingMessagesBubbleImage(with: self.outgoingMessageBubbleColor)
        }
    }

    static let errorDomain: String = "SKYChatConversationViewControllerErrorDomain"

    var errorCreator: SKYErrorCreator {
        return SKYErrorCreator(defaultErrorDomain: SKYChatConversationViewController.errorDomain)
    }

    open func getMessageMediaDataFactory() -> JSQMessageMediaDataFactory {
        return messageMediaDataFactory
    }

    var sendButton: UIButton?
    var recordButton: UIButton?
    var audioRecorder: AVAudioRecorder?
    var inputTextView: UITextView?
    var slideToCancelTextView: UITextView?
    var gesture: UILongPressGestureRecognizer?
    var isRecordingCancelled: Bool = false
    var audioDict: [String: SKYChatConversationAudioItem] = [:]
    var audioTime: TimeInterval?
    var indicator: UIActivityIndicatorView?

    // MARK: - Initializing

    public class func create() -> SKYChatConversationViewController {
        return SKYChatConversationViewController()
    }

    public class func defaultConversationView() -> SKYChatConversationView {
        let frame = UIApplication.shared.keyWindow?.frame ??
                CGRect(x: 0, y: 0, width: 375, height: 667)
        return SKYChatConversationView(frame: frame,
                                       collectionViewLayout: JSQMessagesCollectionViewFlowLayout())
    }

    public init(conversationView: SKYChatConversationView) {
        super.init(collectionView: conversationView,
                   inputToolBar: JSQMessagesViewController.defaultInputToolbar())

    }

    public convenience init() {
        self.init(conversationView: SKYChatConversationViewController.defaultConversationView())
    }

    public required convenience init?(coder aDecoder: NSCoder) {
        self.init()
    }

    open override func awakeFromNib() {
        if (self.collectionView == nil) {
            self.collectionView = SKYChatConversationViewController.defaultConversationView()
        }

        super.awakeFromNib()
    }
}

// MARK: - Lifecycle

extension SKYChatConversationViewController {

    override open func viewDidLoad() {
        super.viewDidLoad()

        self.senderId = self.skygear.auth.currentUserRecordID

        // update the display name after fetching participants
        self.senderDisplayName = NSLocalizedString("me", comment: "")

        UIMenuController.shared.menuItems = [
            UIMenuItem.init(title: "Resend", action: #selector(SKYChatConversationViewController.resendFailedMessage(_:))),
            UIMenuItem.init(title: "Delete", action: #selector(SKYChatConversationViewController.deleteFailedMessage(_:))),
        ]
        JSQMessagesCollectionViewCell.registerMenuAction(#selector(SKYChatConversationViewController.resendFailedMessage(_:)))
        JSQMessagesCollectionViewCell.registerMenuAction(#selector(SKYChatConversationViewController.deleteFailedMessage(_:)))

        self.incomingMessageBubbleColor = UIColor.lightGray
        self.outgoingMessageBubbleColor = UIColor.jsq_messageBubbleBlue()
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard self.conversation != nil else {
            print("Error: Conversation is not set")
            self.dismiss(animated: animated)
            return
        }

        self.customizeViews()

        if self.participants.count == 0 {
            self.fetchParticipants()
        }

        if self.messageList.count == 0 {
            self.fetchUnsentMessages()
            self.fetchMessages(before: nil)
        }

        self.subscribeMessageChanges()
        self.subscribeTypingIndicatorChanges()
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.updateViewsAfterAppear()
    }

    override open func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        self.unsubscribeMessageChanges()
        self.unsubscribeTypingIndicatorChanges()
        self.skygear.chatExtension?.unsubscribeFromUserChannel()
        for (_, audioItem) in self.audioDict {
            audioItem.stop()
        }
    }

    func dismiss(animated: Bool) {
        if let nc = self.navigationController, let topVC = nc.topViewController {
            guard self == topVC else {
                // I am not the top view controller
                return
            }

            nc.popViewController(animated: animated)
        } else {
            self.dismiss(animated: animated, completion: nil)
        }
    }
}

// MARK: - Rendering

extension SKYChatConversationViewController {
    func createSlideToCancelTextView(_ frame: CGRect) -> UITextView {
        let textView = UITextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = false
        textView.text = "Slide to Cancel";
        textView.backgroundColor = UIColor.clear
        textView.textColor = UIColor.darkGray
        return textView
    }

    func createRecordButton(_ frame: CGRect) -> UIButton {
        let recordButton = UIButton(frame: frame)
        recordButton.setImage(UIImage(named: "icon-mic", in: self.bundle(), compatibleWith: nil), for: UIControlState.normal)
        recordButton.tintColor = self.sendButton?.tintColor
        return recordButton
    }

    func reLayout() {
        let contentView = self.inputToolbar?.contentView
        let rightContainerView = contentView?.rightBarButtonContainerView
        rightContainerView?.removeConstraints(rightContainerView?.constraints ?? [])

        var constraints: [NSLayoutConstraint] = []

        if let btn = self.cameraButton {
            constraints.append(contentsOf: [
                NSLayoutConstraint(item: btn,
                                   attribute: .height,
                                   relatedBy: .equal,
                                   toItem: nil,
                                   attribute: .notAnAttribute,
                                   multiplier: 1,
                                   constant: 32),
                NSLayoutConstraint(item: btn,
                                   attribute: .width,
                                   relatedBy: .equal,
                                   toItem: nil,
                                   attribute: .notAnAttribute,
                                   multiplier: 1,
                                   constant: 32),
                NSLayoutConstraint(item: btn,
                                   attribute: .left,
                                   relatedBy: .equal,
                                   toItem: rightContainerView,
                                   attribute: .left,
                                   multiplier: 1,
                                   constant: 8),
                NSLayoutConstraint(item: btn,
                                   attribute: .top,
                                   relatedBy: .equal,
                                   toItem: rightContainerView,
                                   attribute: .top,
                                   multiplier: 1,
                                   constant: 0),
                NSLayoutConstraint(item: btn,
                                   attribute: .bottom,
                                   relatedBy: .equal,
                                   toItem: rightContainerView,
                                   attribute: .bottom,
                                   multiplier: 1,
                                   constant: 0)
            ])
        }

        if let btn = contentView?.rightBarButtonItem {
            constraints.append(contentsOf: [
                NSLayoutConstraint(item: btn,
                                   attribute: .right,
                                   relatedBy: .equal,
                                   toItem: rightContainerView,
                                   attribute: .right,
                                   multiplier: 1,
                                   constant: 0),
                NSLayoutConstraint(item: btn,
                                   attribute: .top,
                                   relatedBy: .equal,
                                   toItem: rightContainerView,
                                   attribute: .top,
                                   multiplier: 1,
                                   constant: 0),
                NSLayoutConstraint(item: btn,
                                   attribute: .bottom,
                                   relatedBy: .equal,
                                   toItem: rightContainerView,
                                   attribute: .bottom,
                                   multiplier: 1,
                                   constant: 0)
                ])

            if let cameraBtn = self.cameraButton {
                constraints.append(
                    NSLayoutConstraint(item: cameraBtn,
                                       attribute: .right,
                                       relatedBy: .equal,
                                       toItem: btn,
                                       attribute: .left,
                                       multiplier: 1,
                                       constant: -8)
                )
            }
        }

        NSLayoutConstraint.activate(constraints)
    }

    func shouldShowCameraButton() -> Bool {
        return
            self.delegate?.cameraButtonShouldShowInConversationViewController?(self) ?? true
    }

    func createActivityIndicator() {
        self.indicator = UIActivityIndicatorView()
        self.indicator?.activityIndicatorViewStyle = .gray
        self.indicator?.hidesWhenStopped = true
        self.view.addSubview(indicator!)
        indicator?.superview?.bringSubview(toFront: indicator!)
        indicator?.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            NSLayoutConstraint(item: self.indicator!, attribute: .centerX, relatedBy: .equal, toItem: self.view, attribute: .centerX, multiplier: 1, constant: 0),
            NSLayoutConstraint(item: self.indicator!, attribute: .centerY, relatedBy: .equal, toItem: self.view, attribute: .centerY, multiplier: 1, constant: 0)
            ])
    }
    
    open func customizeViews() {
        self.updateTitle()

        if let color = self.delegate?.incomingMessageColorForConversationViewController?(self) {
            self.incomingMessageBubbleColor = color
        }

        if let color = self.delegate?.outgoingMessageColorForConversationViewController?(self) {
            self.outgoingMessageBubbleColor = color
        }

        let shouldShowAccessoryButton: Bool =
            self.delegate?.accessoryButtonShouldShowInConversationViewController?(self) ?? true

        if !shouldShowAccessoryButton {
            self.inputToolbar?.contentView?.leftBarButtonItem?.removeFromSuperview()
            self.inputToolbar?.contentView?.leftBarButtonItem = nil
        }

        let shouldShowCameraButton: Bool = self.shouldShowCameraButton()

        if self.sendButton == nil {
            self.sendButton = self.inputToolbar?.contentView?.rightBarButtonItem
            self.sendButton?.removeFromSuperview()
        }

        if self.recordButton == nil {
            self.recordButton = self.createRecordButton(self.sendButton!.frame)
        }

        self.inputTextView = self.inputToolbar?.contentView?.textView
        self.slideToCancelTextView = self.createSlideToCancelTextView(self.inputTextView!.frame)

        if shouldShowCameraButton {
            let cameraButton = UIButton(type: .custom)
            cameraButton.translatesAutoresizingMaskIntoConstraints = false
            cameraButton.setImage(UIImage(named: "icon-camera", in: self.bundle(), compatibleWith: nil), for: .normal)
            cameraButton.addTarget(self, action: #selector(didPressCameraButton(_:)), for: .touchUpInside)
            self.inputToolbar?.contentView?.rightBarButtonContainerView.addSubview(cameraButton)
            self.cameraButton = cameraButton
        }

        self.setRecordButton()
        self.createActivityIndicator()
    }

    open func updateTitle() {
        if let title = self.conversation?.title {
            self.navigationItem.title = title
        } else if let namelist
            = self.conversation?.nameList(fromParticipants: self.participants.map { $0.value },
                                          currentUserID: self.senderId) {

            self.navigationItem.title = namelist
        } else {
            self.navigationItem.title = nil
        }
    }

    open func updateViewsAfterAppear() {
        // UIAppearance got the values from proxy after it is attached to screen
        if self.conversationView?.avatarHiddenForIncomingMessages == true {
            self.conversationView?.collectionViewLayout?.incomingAvatarViewSize
                = CGSize(width: 0, height: 0)
        } else {
            self.conversationView?.collectionViewLayout?.incomingAvatarViewSize = CGSize(
                width: kJSQMessagesCollectionViewAvatarSizeDefault,
                height: kJSQMessagesCollectionViewAvatarSizeDefault
            )
        }

        // UIAppearance got the values from proxy after it is attached to screen
        if self.conversationView?.avatarHiddenForOutgoingMessages == true {
            self.conversationView?.collectionViewLayout?.outgoingAvatarViewSize
                = CGSize(width: 0, height: 0)
        } else {
            self.conversationView?.collectionViewLayout?.outgoingAvatarViewSize = CGSize(
                width: kJSQMessagesCollectionViewAvatarSizeDefault,
                height: kJSQMessagesCollectionViewAvatarSizeDefault
            )
        }
    }

    open override func collectionView(_ collectionView: UICollectionView,
                                      numberOfItemsInSection section: Int) -> Int {
        return self.messageList.count
    }

    open override func collectionView(_ collectionView: JSQMessagesCollectionView!,
                                      messageDataForItemAt indexPath: IndexPath!) -> JSQMessageData! {
        let msg = self.messageList.messageAt(indexPath.row)

        var msgSenderName: String = ""
        if let sender = self.getSenderName(forMessage: msg) as? String {
            msgSenderName = sender
        }

        let isOutgoingMessage = msg.creatorUserRecordID() == self.senderId
        let mediaData = self.messageMediaDataFactory.mediaData(with: msg,
                                                               markedAsOutgoing: isOutgoingMessage)
        let jsqMessage: JSQMessage
        if mediaData == nil {
            jsqMessage = JSQMessage(senderId: msg.creatorUserRecordID(),
                                    senderDisplayName: msgSenderName,
                                    date: msg.creationDate(),
                                    text: msg.body)
        } else {
            jsqMessage = JSQMessage(senderId: msg.creatorUserRecordID(),
                                    senderDisplayName: msgSenderName,
                                    date: msg.creationDate(),
                                    media: mediaData)

            /* Need to store strong reference for audio data
               https://github.com/jessesquires/JSQMessagesViewController/issues/1705
            */
            if let audioItem = mediaData as? SKYChatConversationAudioItem {
                let key = msg.recordID().canonicalString
                if let origAudioItem = self.audioDict[key] {
                    origAudioItem.stop()
                }
                self.audioDict[key] = audioItem
            }
            
            if let imageItem = mediaData as? SKYChatConversationImageItem {
                imageItem.delegate = self
            }
        }

        return jsqMessage
    }

    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        messageBubbleImageDataForItemAt indexPath: IndexPath!
    ) -> JSQMessageBubbleImageDataSource! {
        let msg = self.messageList.messageAt(indexPath.row)

        if msg.creatorUserRecordID() == self.senderId {
            return self.outgoingMessageBubble
        }

        return self.incomingMessageBubble
    }

    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        attributedTextForCellBottomLabelAt indexPath: IndexPath!
    ) -> NSAttributedString! {
        let msg = self.messageList.messageAt(indexPath.row)

        if msg.creatorUserRecordID() != self.senderId {
            return nil
        }

        if msg.fail {
            return NSAttributedString(string: NSLocalizedString("Failed", comment: ""),
                                      attributes: [NSForegroundColorAttributeName: UIColor.red])
        }

        switch msg.conversationStatus {
        case .allRead:
            return NSAttributedString(string: NSLocalizedString("All read", comment: ""))
        case .someRead:
            return NSAttributedString(string: NSLocalizedString("Some read", comment: ""))
        case .delivered:
            return NSAttributedString(string: NSLocalizedString("Delivered", comment: ""))
        case .delivering:
            return NSAttributedString(string: NSLocalizedString("Delivering", comment: ""))
        }
    }

    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        layout collectionViewLayout: JSQMessagesCollectionViewFlowLayout!,
        heightForCellBottomLabelAt indexPath: IndexPath!
    ) -> CGFloat {
        return CGFloat(14)
    }
    
    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        attributedTextForCellTopLabelAt indexPath: IndexPath!
        ) -> NSAttributedString! {
        if let ds = self.delegate?.conversationViewController?(self, dateStringAt: indexPath) {
            return ds
        }

        let msg = self.messageList.messageAt(indexPath.row)
        let date = msg.creationDate()
        
        let dateFormatter: DateFormatter
        dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        dateFormatter.doesRelativeDateFormatting = true
        let dateString = dateFormatter.string(from: date)
        
        return NSAttributedString(string: "\(dateString)")
    }
    
    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        layout collectionViewLayout: JSQMessagesCollectionViewFlowLayout!,
        heightForCellTopLabelAt indexPath: IndexPath!
        ) -> CGFloat {
        var shouldShow: Bool
        if let s = self.delegate?.conversationViewController?(self, shouldShowDateAt: indexPath) {
            shouldShow = s
        } else {
            // default behaviour
            // skip when date string is the same as previous one
            if indexPath.row == 0 {
                shouldShow = true
            } else {
                let thisString = self.collectionView(collectionView,
                                                     attributedTextForCellTopLabelAt: indexPath)
                let lastIndexPath = IndexPath(row: indexPath.row - 1, section: indexPath.section)
                let lastString = self.collectionView(collectionView,
                                                     attributedTextForCellTopLabelAt: lastIndexPath)
                shouldShow = thisString?.string != lastString?.string
            }
        }

        return shouldShow ? CGFloat(20) : CGFloat(0)
    }

    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        attributedTextForMessageBubbleTopLabelAt indexPath: IndexPath!
        ) -> NSAttributedString!
    {
        let msg = self.messageList.messageAt(indexPath.row)
        let senderName = self.getSenderName(forMessage: msg) ?? ""
        let attrStr = NSMutableAttributedString(string: senderName)
        if let color = self.conversationView?.messageSenderTextColor {
            attrStr.setAttributes([NSForegroundColorAttributeName: color],
                                  range: NSMakeRange(0, attrStr.length))
        }
        return attrStr
    }

    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        layout collectionViewLayout: JSQMessagesCollectionViewFlowLayout!,
        heightForMessageBubbleTopLabelAt indexPath: IndexPath!
        ) -> CGFloat {
        var shouldShow: Bool
        if let s
            = self.delegate?.conversationViewController?(self, shouldShowSenderNameAt: indexPath) {
            shouldShow = s
        } else {
            // default behaviour
            // skip when it is "me" or only two members or sender name is the same as previous one
            let msg = self.messageList.messageAt(indexPath.row)
            if msg.creatorUserRecordID() == self.senderId || self.participants.count < 3 {
                shouldShow = false
            } else if indexPath.row == 0 {
                shouldShow = true
            } else {
                let thisString = self.collectionView(
                    collectionView,
                    attributedTextForMessageBubbleTopLabelAt: indexPath
                )
                let lastIndexPath = IndexPath(row: indexPath.row - 1, section: indexPath.section)
                let lastString = self.collectionView(
                    collectionView,
                    attributedTextForMessageBubbleTopLabelAt: lastIndexPath
                )
                shouldShow = thisString?.string != lastString?.string
            }
        }
        return shouldShow ? CGFloat(14) : CGFloat(0)
    }

    open override func collectionView(
        _ collectionView: JSQMessagesCollectionView!,
        avatarImageDataForItemAt indexPath: IndexPath!
    ) -> JSQMessageAvatarImageDataSource! {

        let msg = self.messageList.messageAt(indexPath.row)
        let sender = self.getSender(forMessage: msg)

        // get from delegate
        if let image = self.delegate?.conversationViewController?(
            self,
            avatarForMessage: msg,
            withAuthor: sender,
            atIndexPath: indexPath)
        {
            return JSQMessagesAvatarImage.avatar(with: image)
        }

        if self.conversationView?.avatarType == .image {
            // get from avatar field
            let avatarField = SKYChatUIModelCustomization.default().userAvatarField
            let senderAvatar = sender?.object(forKey: avatarField)
            switch senderAvatar {
            case let senderAvatarUrl as String:
                if let data = self.dataCache.getData(forKey: senderAvatarUrl) {
                    return JSQMessagesAvatarImage.avatar(with: UIImage(data: data))
                }

                // download from url
                let _ = self.downloadDispatcher.download(senderAvatarUrl, compltion: { data in
                    guard let downloadedData = data else {
                        return
                    }

                    // notify to update the avatar when download is done
                    self.dataCache.set(data: downloadedData, forKey: senderAvatarUrl)
                    self.conversationView?.reloadItems(at: [indexPath])
                })
            case let senderAvatarAsset as SKYAsset:
                if let data = self.assetCache.get(asset: senderAvatarAsset) {
                    return JSQMessagesAvatarImage.avatar(with: UIImage(data: data))
                }

                // download asset
                let _ = self.downloadDispatcher.download(
                    senderAvatarAsset.url.absoluteString,
                    compltion: { data in
                        guard let downloadedData = data else {
                            return
                        }

                        // notify to update the avatar when download is done
                        self.assetCache.set(data: downloadedData, for: senderAvatarAsset)
                        self.conversationView?.reloadItems(at: [indexPath])
                })
            default: ()
            }
        }

        // fallback: generate from user name
        let senderName = self.getSenderName(forMessage: msg) ?? ""
        if let avatarImage = UIImage.avatarImage(forInitialsOfName: senderName,
                                                 backgroundColor: self.conversationView?.avatarBackgroundColor,
                                                 textColor: self.conversationView?.avatarTextColor),
            let roundedImage = UIImage.circleImage(fromImage: avatarImage)
        {
            return JSQMessagesAvatarImage.avatar(with: roundedImage)
        }

        print("Error: Cannot generate avatar image")
        return nil
    }

    // Subclasses can override this method to render a custom typing indicator
    open func displayTypingIndicator() {
        guard self.showTypingIndicator == false else {
            // no need to update
            return
        }

        self.showTypingIndicator = true
        if self.automaticallyScrollsToMostRecentMessage {
            self.scrollToBottom(animated: true)
        }
    }

    // Subclasses can override this method to render a custom typing indicator
    open func hideTypingIndicator() {
        guard self.showTypingIndicator == true else {
            // no need to update
            return
        }

        self.showTypingIndicator = false
    }
    
    open func setRecordButton() {
        self.inputToolbar?.contentView?.rightBarButtonItem = self.recordButton
        self.inputToolbar?.contentView?.rightBarButtonItem.removeTarget(self, action: nil, for: UIControlEvents.touchUpInside)
        self.inputToolbar?.contentView?.rightBarButtonItem.removeTarget(self, action: nil, for: UIControlEvents.touchDown)
        self.inputToolbar?.contentView?.rightBarButtonItem.removeTarget(self.inputToolbar, action: nil, for: UIControlEvents.touchUpInside)
        self.inputToolbar?.contentView?.rightBarButtonItem.isEnabled = true
        self.cameraButton?.isHidden = false
        self.gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPressAction(gesture:)))
        self.gesture?.minimumPressDuration = 0.01
        self.inputToolbar?.contentView?.rightBarButtonItem.addGestureRecognizer(self.gesture!)
        if self.shouldShowCameraButton() {
            self.reLayout()
        }
    }
    
    open func setSendButton() {
        self.inputToolbar?.contentView?.rightBarButtonItem.removeGestureRecognizer(self.gesture!)
        self.inputToolbar?.contentView?.rightBarButtonItem = self.sendButton
        self.inputToolbar?.contentView?.rightBarButtonItem.removeTarget(self.inputToolbar, action: nil, for: UIControlEvents.touchUpInside)
        self.inputToolbar?.contentView?.rightBarButtonItem.addTarget(self, action: #selector(didPressSendButton), for: UIControlEvents.touchUpInside)
        if self.shouldShowCameraButton() {
            self.reLayout()
        }
    }
    
    func longPressAction(gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            self.didStartRecord(button: self.recordButton!)
        }
        else {
            var cancelled = gesture.state == .cancelled
            if gesture.state == .changed || gesture.state == .ended {
                guard let view = gesture.view else {
                    return
                }
                
                let point = gesture.location(in: view.superview)
                if point.x < -10 || point.y < -10 {
                    cancelled = true
                }
            }
            
            if cancelled {
                self.didStopRecord(button: self.recordButton!, cancelled: true)
            }
            else if gesture.state == .ended && !cancelled {
                self.didStopRecord(button: self.recordButton!)
            }
        }
    }
    
    open func imageDidTap(_ url: URL?) {
        let photo = SKPhoto.photoWithImageURL(url!.absoluteString)
        let browser = SKPhotoBrowser(photos: [photo])
        
        self.present(browser, animated: true, completion: nil)
    }

    func defaultAccessoryButtonAlertController() -> UIAlertController {
        let alert = UIAlertController(title: "Actions",
                                      message: nil,
                                      preferredStyle: .actionSheet)


        // TODO: support Photo or Video
        alert.addAction(
            UIAlertAction(title: "Photo" /* Photo or Video */, style: .default, handler: self.defaultPhotoPickerActionHandler())
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        return alert
    }

    open func didPressCameraButton(_ sender: UIButton!) {
        // There is always a cropping overlay
        // So just disable it
        let croppingParams = CroppingParameters(isEnabled: false, allowResizing: true, allowMoving: true, minimumSize: CGSize.init(width: 64, height: 64))
        let imagePicker = CameraViewController(croppingParameters: croppingParams,
                                               allowsLibraryAccess: false) { [weak self] image, _ in
                                                if image != nil {
                                                    self?.send(image: image!)

                                                }
                                                self?.dismiss(animated: true, completion: nil)
        }

        self.present(imagePicker, animated: true, completion: nil)
    }
}


// MARK: - Send Message

extension SKYChatConversationViewController {


    func beforeSending(message msg: SKYMessage) {
        // push the "sending" message to message list
        self.messageList.append([msg])
        self.collectionView?.reloadData()

        self.setRecordButton()

        DispatchQueue.main.async {
            self.scrollToBottom(animated: true)
            self.finishSendingMessage(animated: true)
        }

        self.skygear.chatExtension?.sendTypingIndicator(.finished, in: self.conversation!)
        self.delegate?.conversationViewController?(self, readyToSendMessage: msg)
    }
    
    func send(message msg: SKYMessage, done: ((_ sentMsg: SKYMessage) -> Void)? = nil) {
        guard let conv = self.conversation else {
            self.failedToSend(message: msg,
                              errorCode: SKYErrorInvalidArgument,
                              errorMessage: "Cannot send message to nil conversation")
            return
        }

        self.skygear.chatExtension?.addMessage(
            msg,
            to: conv,
            completion: {(result, isCached, error) in
                if isCached {
                    return
                }

                guard error == nil else {
                    print("Failed to sent message: \(error!.localizedDescription)")
                    self.failedToSend(message: msg,
                                      errorCode: SKYErrorBadResponse,
                                      errorMessage: error!.localizedDescription)
                    return
                }
                
                guard let sentMsg = result else {
                    print("Error: Got nil sent message")
                    self.failedToSend(message: msg,
                                      errorCode: SKYErrorBadResponse,
                                      errorMessage: "Got nil sent message")
                    return
                }

                self.successfullySending(message: sentMsg)
                done?(sentMsg)
        })
    }

    func successfullySending(message: SKYMessage) {
        self.messageList.update([message])
        self.collectionView?.reloadData()

        self.delegate?.conversationViewController?(self,
                                                   finishSendingMessage: message)

        /**
         * [JSQMessageViewController finishSendingMessageAnimated:] will set this to false,
         * but we it to be true
         */
        self.inputToolbar?.contentView.rightBarButtonItem.isEnabled = true
    }

    func failedToSend(message: SKYMessage?,
                      errorCode: SKYErrorCode,
                      errorMessage: String)
    {
        if let msg = message {
            self.messageList.update([msg])
            self.collectionView?.reloadData()
        }

        let err = self.errorCreator.error(with: errorCode, message: errorMessage)
        self.delegate?.conversationViewController?(
            self,
            failedToSendMessageText: message?.body ?? "",
            date: message?.creationDate() ?? Date() ,
            error: err)

        /**
         * [JSQMessageViewController finishSendingMessageAnimated:] will set this to false,
         * but we it to be true
         */
        self.inputToolbar?.contentView.rightBarButtonItem.isEnabled = true
    }
}

// MARK: - Actions

extension SKYChatConversationViewController {
    open override func textViewDidChange(_ textView: UITextView) {
        super.textViewDidChange(textView)
        if textView.text.characters.count > 0 {
            self.setSendButton()
        } else {
            self.setRecordButton()
        }
        self.skygear.chatExtension?.sendTypingIndicator(.begin, in: self.conversation!)
    }

    open override func textViewDidEndEditing(_ textView: UITextView) {
        super.textViewDidEndEditing(textView)
        self.skygear.chatExtension?.sendTypingIndicator(.pause, in: self.conversation!)
    }

    open override func didPressAccessoryButton(_ sender: UIButton!) {
        if let alert =
            self.delegate?.conversationViewController?(self,
                                                       alertControllerForAccessoryButton: sender!) {
            self.present(alert, animated: true, completion: nil)
        }
        
        self.present(self.defaultAccessoryButtonAlertController(), animated: true, completion: nil)
    }

    open override func didPressSend(_ button: UIButton!,
                                    withMessageText text: String!,
                                    senderId: String!,
                                    senderDisplayName: String!,
                                    date: Date!) {

        let msg = SKYMessage()
        msg.body = text
        msg.setCreatorUserRecordID(self.senderId)
        msg.setCreationDate(date)

        self.beforeSending(message: msg)
        self.send(message: msg)
    }
    
    open func didPressSendButton(button: UIButton) {
        self.inputToolbar?.delegate.messagesInputToolbar(self.inputToolbar, didPressRightBarButton: button)
    }

    open override func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        self.loadMoreMessage()
    }

    open override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let scrollViewHeight = scrollView.frame.size.height;
        let scrollContentSizeHeight = scrollView.contentSize.height;
        let scrollOffset = scrollView.contentOffset.y;

        if scrollOffset < self.offsetYToLoadMore {
            self.loadMoreMessage()
        }

        // should automaticallyScrollsToMostRecentMessage when reach bottom
        self.automaticallyScrollsToMostRecentMessage = scrollOffset >= scrollContentSizeHeight - scrollViewHeight
    }

    open func loadMoreMessage() {
        if !self.isFetchingMessage && self.hasMoreMessageToFetch {
            if let firstMessage = self.messageList.firstSuccessMessage() {
                self.fetchMessages(before: firstMessage.creationDate())
            } else {
                self.fetchMessages(before: nil)
            }
        }
    }

    open override func collectionView(_ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        let message = self.messageList.messageAt(indexPath.row)
        if !message.fail {
            return super.collectionView(collectionView, canPerformAction: action, forItemAt: indexPath, withSender: sender)
        }

        if action == #selector(SKYChatConversationViewController.resendFailedMessage(_:)) || action == #selector(SKYChatConversationViewController.deleteFailedMessage(_:)) {
            return true
        }

        return false
    }

    open override func collectionView(_ collectionView: UICollectionView, performAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) {
        super.collectionView(collectionView, performAction: action, forItemAt: indexPath, withSender: sender)

        let message = self.messageList.messageAt(indexPath.row)
        if action == #selector(SKYChatConversationViewController.resendFailedMessage(_:)) {
            self.resendFailedMessage(message)
        } else if action == #selector(SKYChatConversationViewController.deleteFailedMessage(_:)) {
            self.deleteFailedMessage(message)
        }
    }

    @objc func resendFailedMessage(_ message: SKYMessage) {
        self.messageList.remove([message])
        self.beforeSending(message: message)
        self.send(message: message)
        self.collectionView.reloadData()
    }

    @objc func deleteFailedMessage(_ message: SKYMessage) {
        self.messageList.remove([message])
        self.collectionView.reloadData()
    }
}

// MARK: - Default accessory action handler

extension SKYChatConversationViewController {
    public func defaultPhotoPickerActionHandler() -> (UIAlertAction) -> Swift.Void {
        return { _ in
            let picker = CTAssetsPickerController()
            picker.delegate = self
            picker.assetsFetchOptions = PHFetchOptions()
            picker.assetsFetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
            self.present(picker, animated: true, completion: nil)
        }
    }
}

// MARK: - CTAssetsPickerControllerDelegate

extension SKYChatConversationViewController: CTAssetsPickerControllerDelegate {
    public func assetsPickerController(_ picker: CTAssetsPickerController!, didFinishPickingAssets assets: [Any]!) {
        for asset in assets {
            switch asset {
            case let a as PHAsset:
                self.send(asset: a)
            default:
                NSLog("Unknown asset type")
            }
        }
        picker.dismiss(animated: true, completion: nil)
    }
}


// MARK: - Send photos

extension SKYChatConversationViewController {
    func cleanup(asset: SKYAsset) {
        try? FileManager.default.removeItem(at: asset.url)
    }

    open func send(asset: PHAsset) {
        let manager = PHImageManager.default()
        let option = PHImageRequestOptions()
        option.resizeMode = .fast
        option.deliveryMode = .fastFormat
        manager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: option,
            resultHandler: { (result, _) in
                if result != nil {
                    self.send(image: result!)
                }
        })
    }

    open func send(image: UIImage) {
        let date = Date()

        guard self.conversation != nil else {
            self.failedToSend(message: nil,
                              errorCode: SKYErrorInvalidArgument,
                              errorMessage: "Cannot send message to nil conversation")
            return
        }

        let msg = SKYMessage(withImage: image)
        msg.setCreatorUserRecordID(self.senderId)
        msg.setCreationDate(date)

        self.beforeSending(message: msg)
        self.send(message: msg)
    }
}

// MARK: - Audio

extension SKYChatConversationViewController {
    func startRecord() {
        print("Voice Recording: Start Recording")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording.m4a")
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        DispatchQueue.global().async {
            do {
                if (self.audioRecorder == nil) {
                    self.audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                    self.audioRecorder?.delegate = self
                    self.audioRecorder?.prepareToRecord()
                }

                self.audioRecorder?.record()
            } catch {
                // TODO: show dialog
            }
        }
    }
    
    func didStartRecord(button: UIButton) {
        print("Voice Recording: Recording Button Did Pressed Down")

        let recordingSession = AVAudioSession.sharedInstance()
        if recordingSession.recordPermission() == .granted {
            do {
                try recordingSession.setCategory(AVAudioSessionCategoryPlayAndRecord)
                try recordingSession.setActive(true)
                self.inputTextView?.isHidden = true
                self.inputToolbar?.contentView?.leftBarButtonItem?.isHidden = true
                self.inputToolbar?.contentView?.addSubview(self.slideToCancelTextView!)
                self.cameraButton?.isHidden = true
                self.startRecord()
            } catch {
                print("Cannot start recording session.")
            }
        } else {
            recordingSession.requestRecordPermission() { allowed in }
        }
    }
    
    open func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("Voice Recording: Audio Recorder Finished")

        if !flag || self.isRecordingCancelled {
            print("Voice Recording: Cancelled")
            self.setRecordButton()
            return
        }

        let asset: SKYAsset
        do {
            asset = SKYAsset(data: try Data(contentsOf: recorder.url))
        } catch {
            let alert = UIAlertController(
                title: "Unable to send voice messaage",
                message: "Failed to construct voice data",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK",
                                          style: .default,
                                          handler: nil))
            self.present(alert, animated: true, completion: nil)

            return
        }

        asset.mimeType = "audio/m4a"

        let msg = SKYMessage()
        msg.body = ""
        msg.metadata = ["length": Int(self.audioTime! * 1000)]
        msg.attachment = asset
        msg.setCreatorUserRecordID(self.senderId)
        msg.setCreationDate(Date())

        self.beforeSending(message: msg)
        self.send(message: msg)
    }
    
    func didStopRecord(button: UIButton, cancelled: Bool = false) {
        let recordingSession = AVAudioSession.sharedInstance()
        if recordingSession.recordPermission() == .granted {
            print("Voice Recording: Stop recording \(cancelled ? "(cancelled)" : "")")
            self.setRecordButton()
            self.isRecordingCancelled = cancelled
            self.slideToCancelTextView?.removeFromSuperview()
            self.inputTextView?.isHidden = false
            self.inputToolbar?.contentView?.leftBarButtonItem?.isHidden = false
            self.audioTime = self.audioRecorder?.currentTime
            DispatchQueue.global().async {
                self.audioRecorder?.stop()
                do {
                    try recordingSession.setActive(false)
                } catch {
                    print("Failed to stop recording session.")
                }
            }
            print("Voice Recording: Recording Stopped")
        }
    }
}

extension SKYChatConversationViewController {

    open func subscribeMessageChanges() {

        self.unsubscribeMessageChanges()

        let handler: ((SKYChatRecordChangeEvent, SKYMessage) -> Void) = {(event, msg) in
            let msgID = msg.recordID().recordName
            let foundMessage = self.messageList.contains(msgID)

            switch event {
            case .create:
                if foundMessage {
                    self.messageList.update([msg])
                } else {
                    self.messageList.append([msg])
                }

                self.skygear.chatExtension?.markReadMessages([msg], completion: nil)
                self.skygear.chatExtension?.markLastReadMessage(msg,
                                                                in: self.conversation!,
                                                                completion: nil)

                self.delegate?.conversationViewController?(self, didFetchedMessages: [msg], isCached: false)

                self.finishReceivingMessage()
            case .update:
                if foundMessage {
                    self.messageList.update([msg])
                    self.collectionView.reloadData()
                    self.collectionView.layoutIfNeeded()
                }
            case .delete:
                if foundMessage {
                    self.messageList.remove([msg])
                    self.collectionView.reloadData()
                    self.collectionView.layoutIfNeeded()
                }
            }
        }

        self.messageChangeObserver = self.skygear.chatExtension?
            .subscribeToMessages(in: self.conversation!, handler: handler)

    }

    open func unsubscribeMessageChanges() {
        if let observer = self.messageChangeObserver {
            self.skygear.chatExtension?.unsubscribeToMessages(withObserver: observer)
            self.messageChangeObserver = nil
        }
    }

    open func subscribeTypingIndicatorChanges() {

        self.unsubscribeTypingIndicatorChanges()

        let handler: ((SKYChatTypingIndicator) -> Void) = {(indicator) in
            // invalidate the existing timer
            if let timer = self.typingIndicatorPromptTimer {
                timer.invalidate()
                self.typingIndicatorPromptTimer = nil
            }

            let shouldShowIndicator: Bool = indicator.userIDs
                .flatMap({ SKYRecordID(canonicalString: $0).recordName })
                .filter({ $0 != self.senderId })
                .count > 0

            if shouldShowIndicator {
                self.displayTypingIndicator()

                // schedule a timer to hide the typing indicator
                self.typingIndicatorPromptTimer =
                    Timer.scheduledTimer(timeInterval: self.typingIndicatorShowDuration,
                                         target: self,
                                         selector: #selector(self.hideTypingIndicator),
                                         userInfo: nil,
                                         repeats: false)
            } else {
                self.hideTypingIndicator()
            }
        }

        self.typingIndicatorChangeObserver = self.skygear.chatExtension?
            .subscribeToTypingIndicator(in: self.conversation!, handler: handler)
    }

    open func unsubscribeTypingIndicatorChanges() {
        if let observer = self.typingIndicatorChangeObserver {
            self.skygear.chatExtension?.unsubscribeToTypingIndicator(withObserver: observer)
            self.typingIndicatorChangeObserver = nil
        }
    }
}

// MARK: - Utility Methods

extension SKYChatConversationViewController {

    open func fetchParticipants() {
        guard self.conversation != nil else {
            print("Cannot fetch participants with nil conversation")
            return
        }

        let participantIDs = self.conversation!.participantIds
            .map { (eachParticipantID) -> SKYRecordID in
                return SKYRecordID(recordType: "user", name: eachParticipantID)
            }

        self.skygear.publicCloudDatabase
            .fetchRecords(with: participantIDs, completionHandler: { (result, error) in
                guard error == nil else {
                    print("Failed to fetch participants: \(error?.localizedDescription ?? "")")
                    self.delegate?.conversationViewController?(
                        self, failedFetchingParticipantWithError: error!)

                    return
                }

                guard let participantMap = result as? [SKYRecordID: SKYRecord] else {
                    print("Fetched participants are in wrong format")
                    let err = self.errorCreator.error(
                        with: SKYErrorBadResponse,
                        message: "Fetched participants are in wrong format")

                    self.delegate?.conversationViewController?(
                        self, failedFetchingParticipantWithError: err)

                    return
                }

                var participants: [SKYRecord] = []
                for (k, v) in participantMap {
                    self.participants[k.recordName] = v
                    participants.append(v)
                }

                if let senderRecord = self.participants[self.senderId] {
                    let userNameField = SKYChatUIModelCustomization.default().userNameField
                    if let senderName = senderRecord.object(forKey: userNameField) as? String {
                        self.senderDisplayName = senderName
                    }
                }

                self.updateTitle()

                self.delegate?.conversationViewController?(
                    self, didFetchedParticipants: participants)

                self.collectionView?.reloadData()
                self.collectionView?.layoutIfNeeded()

            }, perRecordErrorHandler: nil)
    }

    open func fetchUnsentMessages() {
        let chatExt = self.skygear.chatExtension
        chatExt?.fetchUnsentMessages(conversationID: self.conversation!.recordID().recordName,
                                     completion: { (unsentMessages) in
                                        self.delegate?.conversationViewController?(self, didFetchedMessages: unsentMessages, isCached: true)
                                        self.messageList.merge(unsentMessages)
                                        self.finishReceivingMessage()
        })
    }

    open func fetchMessages(before: Date?) {
        guard self.conversation != nil else {
            print("Cannot fetch messages with nil conversation")
            return
        }

        if self.messageList.count == 0 {
            self.indicator?.startAnimating()
        }

        let chatExt = self.skygear.chatExtension
        self.isFetchingMessage = true

        let cachedResult = NSMutableArray()

        self.delegate?.startFetchingMessages?(self)
        chatExt?.fetchMessages(
            conversation: self.conversation!,
            limit: Int(self.messagesFetchLimit),
            beforeTime: before,
                 order: nil,
            completion: { (result, isCached, error) in
                if isCached {
                    if (result?.count ?? 0) > 0 {
                        self.indicator?.stopAnimating()
                    }

                    cachedResult.addObjects(from: result!)
                } else {
                    self.isFetchingMessage = false
                    self.indicator?.stopAnimating()

                    guard error == nil else {
                        print("Failed to fetch messages: \(error?.localizedDescription ?? "")")
                        self.delegate?.conversationViewController?(
                            self, failedFetchingMessagesWithError: error!)

                        return
                    }
                }

                guard let msgs = result else {
                    print("Failed to get any messages")
                    let err = self.errorCreator.error(
                        with: SKYErrorBadResponse, message: "Failed to get any messages")

                    self.delegate?.conversationViewController?(
                        self, failedFetchingMessagesWithError: err)

                    return
                }

                if !isCached {
                    if let cachedMessages = cachedResult as? [SKYMessage] {
                        self.messageList.remove(cachedMessages)
                    }
                }
                self.messageList.merge(msgs)

                if !isCached {
                    if msgs.count > 0, let first = msgs.first {
                        // this is the first page
                        chatExt?.markReadMessages(msgs, completion: nil)
                        chatExt?.markLastReadMessage(first,
                                                     in: self.conversation!,
                                                     completion: nil)
                    }
                }

                self.delegate?.conversationViewController?(self, didFetchedMessages: msgs, isCached: isCached)

                self.hasMoreMessageToFetch = msgs.count > 0

                let bottomOffset = self.collectionView.contentSize.height - self.collectionView.contentOffset.y

                self.finishReceivingMessage()

                // force collection view layout
                // to allow new content offset calculated
                self.collectionView.layoutIfNeeded()

                let offsetY = max(min(self.collectionView.contentSize.height - self.collectionView.frame.size.height,
                                  self.collectionView.contentSize.height - bottomOffset), 0)
                self.collectionView.contentOffset = CGPoint(x: 0, y: offsetY)
                self.collectionView.flashScrollIndicators()
        })
    }

    open func getSender(forMessage message: SKYMessage) -> SKYRecord? {
        let msgAuthorID = message.creatorUserRecordID()

        guard self.participants.keys.contains(msgAuthorID) else {
            print("Warning: Participant ID \(msgAuthorID) is not fetched")
            return nil
        }

        return self.participants[msgAuthorID]
    }

    open func getSenderName(forMessage message: SKYMessage) -> String? {
        guard let sender = self.getSender(forMessage: message) else {
            return nil
        }

        let userNameField = SKYChatUIModelCustomization.default().userNameField
        return sender.object(forKey: userNameField) as? String
    }
}

// MARK: Resource

extension SKYChatConversationViewController {
    open func bundle() -> Bundle? {
        let podBundle = Bundle(for: SKYChatConversationViewController.self)
        let bundleUrl = podBundle.url(forResource: "SKYKitChatUI", withExtension:"bundle")
        let bundle = Bundle(url: bundleUrl!)
        return bundle
    }
}
