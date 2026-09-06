import Cocoa

// Remote-notification menu: construction, state refresh and handlers,
// kept out of AppDelegate's core to minimize merge conflicts upstream.
extension AppDelegate {
    private static let notifyRSSIMenuItemKind = "notifyRSSI"

    func constructRemoteNotifyMenu() {
        let notifyItem = mainMenu.addItem(withTitle: t("remote_notify"), action: nil, keyEquivalent: "")
        notifyItem.submenu = notifyMenu
        notifyMenu.delegate = self
        notifyMenu.addItem(withTitle: t("notify_min_rssi"), action: nil, keyEquivalent: "")
        let noteItem = notifyMenu.addItem(withTitle: t("notify_threshold_note"), action: nil, keyEquivalent: "")
        noteItem.isEnabled = false
        addSettingsItem(notifyMenu, title: t("always_notify"), action: #selector(setNotifyRSSI(_:)), tag: 0, kind: AppDelegate.notifyRSSIMenuItemKind)
        notifyMenu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            addSettingsItem(notifyMenu, title: String(format: "%ddBm", proximity), action: #selector(setNotifyRSSI(_:)), tag: proximity, kind: AppDelegate.notifyRSSIMenuItemKind)
        }
        notifyMenu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        notifyMenu.addItem(NSMenuItem.separator())
        notifyMenu.addItem(withTitle: t("notify_events"), action: nil, keyEquivalent: "")
        for event in notifyEventNames {
            let eventItem = notifyMenu.addItem(withTitle: t("notify_event_" + event), action: #selector(toggleNotifyEvent(_:)), keyEquivalent: "")
            eventItem.representedObject = event
        }
        notifyMenu.addItem(NSMenuItem.separator())
        let photoItem = notifyMenu.addItem(withTitle: t("notify_with_photo"), action: #selector(toggleNotifyPhoto(_:)), keyEquivalent: "")
        photoItem.state = prefs.bool(forKey: RemoteNotifier.notifyWithPhotoKey) ? .on : .off
        let savePhotoItem = notifyMenu.addItem(withTitle: t("save_photo_locally"), action: #selector(toggleNotifySavePhoto(_:)), keyEquivalent: "")
        savePhotoItem.state = prefs.bool(forKey: RemoteNotifier.savePhotoLocallyKey) ? .on : .off
        notifyMenu.addItem(withTitle: t("open_photo_folder"), action: #selector(openPhotoFolder), keyEquivalent: "")
        notifyMenu.addItem(NSMenuItem.separator())
        notifyMenu.addItem(withTitle: t("notify_channels"), action: nil, keyEquivalent: "")
        for (channel, title, configAction) in [
            ("telegram", "Telegram", #selector(setupTelegram)),
            ("bark", "Bark", #selector(setupBark)),
            ("wecom", t("wecom_short"), #selector(setupWecom)),
        ] {
            let channelItem = notifyMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            channelItem.representedObject = "notifyChannel"
            let sub = NSMenu()
            let enableItem = sub.addItem(withTitle: t("notify_channel_enabled"), action: #selector(toggleNotifyChannel(_:)), keyEquivalent: "")
            enableItem.representedObject = channel
            sub.addItem(withTitle: t("channel_config"), action: configAction, keyEquivalent: "")
            channelItem.submenu = sub
        }
        notifyMenu.addItem(withTitle: t("send_test_notification"), action: #selector(sendTestNotification), keyEquivalent: "")
        refreshNotifyMenu()
    }


    private static let notifyRSSIMenuItemKind = "notifyRSSI"

    func refreshNotifyMenu() {
        let minRSSI = prefs.integer(forKey: RemoteNotifier.notifyMinRSSIKey)
        for item in notifyMenu.items {
            if item.representedObject as? String == AppDelegate.notifyRSSIMenuItemKind {
                item.state = item.tag == minRSSI ? .on : .off
            } else if let event = item.representedObject as? String, let key = notifyEventKey(for: event) {
                item.state = prefs.bool(forKey: key) ? .on : .off
            } else if item.representedObject as? String == "notifyChannel",
                      let channel = item.submenu?.items.first?.representedObject as? String {
                let enabled = remoteNotifier.channelEnabled(channel) && remoteNotifier.isChannelConfigured(channel)
                item.state = enabled ? .on : .off
                // Keep the submenu's enable item in sync — otherwise a stale
                // unchecked display would make the next click flip a stored
                // "on" back off.
                item.submenu?.items.first?.state = remoteNotifier.channelEnabled(channel) ? .on : .off
            }
        }
    }

    @objc func setNotifyRSSI(_ menuItem: NSMenuItem) {
        prefs.set(menuItem.tag, forKey: RemoteNotifier.notifyMinRSSIKey)
        refreshNotifyMenu()
    }

    // The log-stream subprocess only needs to run while someone listens to
    // the authFailed event.
    func syncAuthFailureMonitor() {
        if prefs.bool(forKey: notifyEventKey(for: "authFailed") ?? "") {
            authFailureMonitor.start()
        } else {
            authFailureMonitor.stop()
        }
    }

    @objc func toggleNotifyChannel(_ menuItem: NSMenuItem) {
        guard let channel = menuItem.representedObject as? String else { return }
        let value = !remoteNotifier.channelEnabled(channel)
        RemoteNotifier.setChannelEnabled(channel, value)
        menuItem.state = value ? .on : .off
        refreshNotifyMenu()
    }

    @objc func toggleNotifyEvent(_ menuItem: NSMenuItem) {
        guard let event = menuItem.representedObject as? String, let key = notifyEventKey(for: event) else { return }
        prefs.set(!prefs.bool(forKey: key), forKey: key)
        if event == "authFailed" {
            syncAuthFailureMonitor()
        }
        refreshNotifyMenu()
    }

    @objc func toggleNotifyPhoto(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: RemoteNotifier.notifyWithPhotoKey)
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: RemoteNotifier.notifyWithPhotoKey)
        // Ask for camera consent up front, instead of at the next event trigger.
        if value, #available(macOS 10.15, *) {
            PhotoCapture.requestAccess()
        }
    }

    @objc func setupTelegram() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("telegram_settings")
        msg.informativeText = t("telegram_settings_info")
        msg.window.title = "BLEUnlock"

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        stack.orientation = .vertical
        let tokenField = NSTextField(frame: NSRect(x: 0, y: 36, width: 300, height: 22))
        tokenField.placeholderString = "Bot token (123456:ABC-DEF...)"
        tokenField.stringValue = remoteNotifier.telegramToken
        let chatField = NSTextField(frame: NSRect(x: 0, y: 8, width: 300, height: 22))
        chatField.placeholderString = "Chat ID"
        chatField.stringValue = remoteNotifier.telegramChatID
        stack.addArrangedSubview(tokenField)
        stack.addArrangedSubview(chatField)
        msg.accessoryView = stack
        tokenField.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        if msg.runModal() == .alertFirstButtonReturn {
            RemoteNotifier.setTelegram(token: tokenField.stringValue.trimmingCharacters(in: .whitespaces),
                                       chatID: chatField.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    @objc func toggleNotifySavePhoto(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: RemoteNotifier.savePhotoLocallyKey)
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: RemoteNotifier.savePhotoLocallyKey)
    }

    @objc func openPhotoFolder() {
        let dir = RemoteNotifier.photoDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func setupWecom() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("wecom_settings")
        msg.informativeText = t("wecom_settings_info")
        msg.window.title = "BLEUnlock"

        let keyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        keyField.placeholderString = "Webhook key (693axxx-...)"
        keyField.stringValue = remoteNotifier.wecomKey
        msg.accessoryView = keyField
        keyField.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        if msg.runModal() == .alertFirstButtonReturn {
            RemoteNotifier.setWecom(key: keyField.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    @objc func setupBark() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("bark_settings")
        msg.informativeText = t("bark_settings_info")
        msg.window.title = "BLEUnlock"

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        stack.orientation = .vertical
        let serverField = NSTextField(frame: NSRect(x: 0, y: 36, width: 300, height: 22))
        serverField.placeholderString = "https://api.day.app"
        serverField.stringValue = remoteNotifier.barkServer
        let keyField = NSTextField(frame: NSRect(x: 0, y: 8, width: 300, height: 22))
        keyField.placeholderString = "Device key"
        keyField.stringValue = remoteNotifier.barkDeviceKey
        stack.addArrangedSubview(serverField)
        stack.addArrangedSubview(keyField)
        msg.accessoryView = stack
        serverField.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        if msg.runModal() == .alertFirstButtonReturn {
            RemoteNotifier.setBark(server: serverField.stringValue.trimmingCharacters(in: .whitespaces),
                                   deviceKey: keyField.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    @objc func sendTestNotification() {
        if !remoteNotifier.hasChannel {
            errorModal(t("notify_no_channel"))
            return
        }
        remoteNotifier.sendTest()
    }
}
