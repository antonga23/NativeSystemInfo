import AppKit
import SwiftUI
import Combine

/// AppKit shell that reproduces Apple's System Information layout: a 200pt source-list
/// sidebar with 15pt rows, tab-aligned 13pt report text, and a status bar. Measured from a
/// 2x capture of the native window (910x602): sidebar 200pt, header 15pt in / 49pt down,
/// label column at 21pt, value column at 165pt, row pitch 15pt, status bar 32pt.
final class MainViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let store: SPReportStore
    private var bag = Set<AnyCancellable>()

    private let outline = NSOutlineView()
    private let sidebarScroll = NSScrollView()
    private let contentScroll = NSScrollView()
    private let textView = NSTextView()
    private var dmHost: NSHostingView<DeviceManagementPane>?
    /// Apple's status bar is a real NSPathControl, not a joined string - using one gets the
    /// chevron glyph, icon placement, 13pt metrics, truncation and click behaviour for free.
    private let pathControl = NSPathControl()

    // Table half of the content column. Hidden entirely for panes Apple gives no columns
    // (Hardware, Language & Region) and for panes whose table comes back empty.
    private let tableOutline = NSOutlineView()
    private let tableScroll = NSScrollView()
    private let detailSplit = NSSplitView()
    private var tableRows: [SPNode] = []
    private var currentColumns: [SPColumns.Column] = []
    private var splitHost: NSView!
    private var contentColumn: NSView!
    /// Apple shows the model name as a bold 13pt title at the top of the content column,
    /// with no toolbar band. The window's own title is hidden and this label stands in.
    private let titleLabel = NSTextField(labelWithString: "")
    private let sidebarItem = NSSplitViewItem()

    private enum Node: Hashable { case group(SPGroup), item(SPGroup, SPItem), management, dm }

    init(store: SPReportStore) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 910, height: 602))
        preferredContentSize = NSSize(width: 910, height: 602)   // otherwise the window shrinks to the split view's 209pt fitting width

        // sidebar
        outline.headerView = nil
        outline.rowHeight = 15
        outline.indentationPerLevel = 16
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        sidebarScroll.documentView = outline
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        outline.backgroundColor = .clear

        // report text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 15, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        contentScroll.documentView = textView
        contentScroll.hasVerticalScroller = true
        contentScroll.hasHorizontalScroller = true
        contentScroll.drawsBackground = false

        // status bar
        let status = NSView()
        let sep = NSBox(); sep.boxType = .separator
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.backgroundColor = .clear
        pathControl.focusRingType = .none
        for v in [sep, pathControl] { v.translatesAutoresizingMaskIntoConstraints = false; status.addSubview(v) }
        // content column: title + report
        let content = NSView(); contentColumn = content
        // Without these the split view's fitting width is 200 + 1pt and the window shrinks to
        // 209pt when the controller is installed. Apple's window is 910x602.
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 702).isActive = true
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // table (top) over text detail (bottom), as Apple's panes are arranged
        tableOutline.headerView = NSTableHeaderView()
        tableOutline.rowHeight = 17
        tableOutline.usesAlternatingRowBackgroundColors = true
        tableOutline.indentationPerLevel = 14
        tableOutline.style = .plain
        tableOutline.allowsColumnResizing = true
        tableOutline.dataSource = self
        tableOutline.delegate = self
        tableOutline.target = self
        tableScroll.documentView = tableOutline
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true

        detailSplit.isVertical = false
        detailSplit.dividerStyle = .thin
        detailSplit.addArrangedSubview(tableScroll)
        detailSplit.addArrangedSubview(contentScroll)
        detailSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        detailSplit.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
        detailSplit.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel); content.addSubview(detailSplit); content.addSubview(status)
        status.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            detailSplit.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            detailSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detailSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailSplit.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 34),
        ])
        let sideVC = NSViewController(); sideVC.view = sidebarScroll
        let mainVC = NSViewController(); mainVC.view = content
        let svc = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sideVC)
        sideItem.minimumThickness = 200; sideItem.maximumThickness = 200; sideItem.canCollapse = false
        svc.addSplitViewItem(sideItem)
        svc.addSplitViewItem(NSSplitViewItem(viewController: mainVC))
        addChild(svc)
        splitHost = svc.view

        splitHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitHost)
        NSLayoutConstraint.activate([
            splitHost.topAnchor.constraint(equalTo: view.topAnchor),
            splitHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sep.topAnchor.constraint(equalTo: status.topAnchor),
            sep.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            pathControl.leadingAnchor.constraint(equalTo: sep.leadingAnchor, constant: 7),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: status.trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            pathControl.heightAnchor.constraint(equalToConstant: 22),
        ])
                sidebarScroll.contentInsets = NSEdgeInsets(top: 26, left: 0, bottom: 0, right: 0)

        bind()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        Log.mark("layout: view \(NSStringFromRect(view.frame)) split \(NSStringFromRect(splitHost.frame)) sidebar \(NSStringFromRect(sidebarScroll.frame)) content \(NSStringFromRect(contentColumn.frame)) scroll \(NSStringFromRect(contentScroll.frame))")
    }

    private func bind() {
        store.$groups.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.outline.reloadData(); self?.outline.expandItem(nil, expandChildren: true); self?.syncSelection()
        }.store(in: &bag)
        store.$selection.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncSelection(); self?.render() }.store(in: &bag)
        store.$states.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        store.$deviceManagement.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        store.$serialNumber.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        store.$computerName.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        store.$modelName.receive(on: DispatchQueue.main).sink { [weak self] n in self?.titleLabel.stringValue = n }.store(in: &bag)
        outline.reloadData(); outline.expandItem(nil, expandChildren: true)
    }

    // MARK: - tree

    private func roots() -> [Node] { store.groups.map { .group($0) } + [.management] }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if o === tableOutline {
            guard let node = item as? SPNode else { return tableRows.count }
            return node.children.filter { $0.kind == .section }.count
        }
        guard let node = item as? Node else { return roots().count }
        switch node { case .group(let g): return g.items.count; case .management: return 1; default: return 0 }
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if o === tableOutline {
            guard let node = item as? SPNode else { return tableRows[index] }
            return node.children.filter { $0.kind == .section }[index]
        }
        guard let node = item as? Node else { return roots()[index] }
        switch node { case .group(let g): return Node.item(g, g.items[index]); case .management: return Node.dm; default: fatalError() }
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if o === tableOutline {
            guard let node = item as? SPNode else { return false }
            return node.children.contains { $0.kind == .section }
        }
        if case .item = item as! Node { return false }; if case .dm = item as! Node { return false }; return true
    }
    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        if o === tableOutline {
            guard let node = item as? SPNode, let column = c else { return nil }
            return tableCell(for: node, column: column, in: o)
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView(); v.identifier = id
            let t = NSTextField(labelWithString: ""); t.font = .systemFont(ofSize: 11); t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(t); v.textField = t
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                                         t.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                         t.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v }()
        cell.textField?.stringValue = title(for: item as! Node)
        return cell
    }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        o === tableOutline ? 17 : 15
    }

    /// First column shows the record's own label; the rest match a child pair by its label.
    /// Header strings come from Apple's own localised tables, so they line up with the
    /// labels system_profiler emits in the same locale.
    private func tableCell(for node: SPNode, column: NSTableColumn, in o: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("spcell")
        let cell = (o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView(); v.identifier = id
            let t = NSTextField(labelWithString: ""); t.font = .systemFont(ofSize: 11)
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(t); v.textField = t
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                                         t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
                                         t.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v }()

        if column.identifier.rawValue == "__name__" {
            cell.textField?.stringValue = node.label
        } else {
            let wanted = column.title.lowercased()
            let match = node.children.first { $0.kind == .pair && $0.label.lowercased() == wanted }
            cell.textField?.stringValue = match?.value ?? ""
        }
        return cell
    }

    private func rebuildTable(for selection: Selection, nodes: [SPNode]) {
        while let col = tableOutline.tableColumns.last { tableOutline.removeTableColumn(col) }
        currentColumns = SPColumns.columns(for: selection.dataType)
        tableRows = SPReport.rows(in: nodes)

        // No declared columns, or nothing to put in them: Apple shows the text pane alone.
        guard !currentColumns.isEmpty, !tableRows.isEmpty else {
            tableScroll.isHidden = true
            tableOutline.reloadData()
            return
        }
        tableScroll.isHidden = false

        for (index, column) in currentColumns.enumerated() {
            let id = NSUserInterfaceItemIdentifier(index == 0 ? "__name__" : column.key)
            let col = NSTableColumn(identifier: id)
            col.title = column.title
            col.width = index == 0 ? 280 : 150
            col.minWidth = 40
            tableOutline.addTableColumn(col)
            if index == 0 { tableOutline.outlineTableColumn = col }
        }
        tableOutline.reloadData()
        // Apple keeps exactly one row selected once a table is populated.
        if tableOutline.numberOfRows > 0 {
            tableOutline.selectRowIndexes([0], byExtendingSelection: false)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tableScroll.isHidden else { return }
            let h = self.detailSplit.bounds.height
            if h > 120 { self.detailSplit.setPosition(h * 0.45, ofDividerAt: 0) }
        }
    }

    /// Breadcrumb: computer name > group > pane > selected row ancestry (first column only,
    /// unbounded depth). Stops at the last known element - no trailing separator.
    private func updatePath(for selection: Selection) {
        var parts = [store.computerName]
        if let group = store.groups.first(where: { g in g.id == selection.dataType || g.items.contains { $0.id == selection.dataType } }) {
            parts.append(group.name)
            if group.id != selection.dataType { parts.append(selection.title) }
        } else {
            parts.append(selection.title)
        }
        if tableOutline.selectedRow >= 0, let node = tableOutline.item(atRow: tableOutline.selectedRow) as? SPNode {
            var chain: [String] = []
            var current: SPNode? = node
            while let n = current {
                chain.insert(n.label, at: 0)
                current = tableRows.contains(where: { $0 === n }) ? nil : parent(of: n, in: tableRows)
            }
            parts.append(contentsOf: chain)
        }
        pathControl.pathItems = parts.enumerated().map { index, text in
            let item = NSPathControlItem()
            item.title = text
            if index == 0 {
                let icon = NSImage(named: NSImage.computerName)
                icon?.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            return item
        }
    }

    private func parent(of node: SPNode, in roots: [SPNode]) -> SPNode? {
        for root in roots {
            if root.children.contains(where: { $0 === node }) { return root }
            if let found = parent(of: node, in: root.children) { return found }
        }
        return nil
    }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    private func title(for n: Node) -> String {
        switch n { case .group(let g): return g.name; case .item(_, let i): return i.name
                   case .management: return "Management"; case .dm: return Selection.deviceManagement.title }
    }
    private func selection(for n: Node) -> Selection {
        switch n { case .group(let g): return Selection(dataType: g.id, title: g.name)
                   case .item(_, let i): return Selection(dataType: i.id, title: i.name)
                   case .management, .dm: return Selection.deviceManagement }
    }

    private var syncing = false
    func outlineViewSelectionDidChange(_ n: Notification) {
        if (n.object as AnyObject?) === tableOutline {
            renderDetail()
            if let sel = store.selection { updatePath(for: sel) }
            return
        }
        guard !syncing, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        let sel = selection(for: node)
        if store.selection != sel { store.selection = sel }
        if sel == .deviceManagement { store.loadDeviceManagement() } else { store.request(sel.dataType) }
    }

    private func syncSelection() {
        guard let sel = store.selection else { return }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, selection(for: node) == sel {
                if outline.selectedRow != row { syncing = true; outline.selectRowIndexes([row], byExtendingSelection: false); syncing = false }
                return
            }
        }
    }

    // MARK: - content

    private func render() {
        let sel = store.selection ?? .hardware

        if sel == .deviceManagement {
            tableScroll.isHidden = true
            updatePath(for: sel)
            if dmHost == nil {
                let h = NSHostingView(rootView: DeviceManagementPane(info: store.deviceManagement))
                dmHost = h
            } else {
                dmHost?.rootView = DeviceManagementPane(info: store.deviceManagement)
            }
            if contentScroll.documentView !== dmHost { contentScroll.documentView = dmHost; dmHost?.frame = contentScroll.bounds; dmHost?.autoresizingMask = [.width, .height] }
            return
        }
        if contentScroll.documentView !== textView { contentScroll.documentView = textView }

        if case .loaded(let nodes) = store.state(for: sel.dataType) {
            rebuildTable(for: sel, nodes: nodes)
        } else {
            tableScroll.isHidden = true
            tableRows = []; currentColumns = []
            tableOutline.reloadData()
        }
        renderDetail()
        updatePath(for: sel)
    }

    /// The text half. With a table present it shows the selected record; without one it
    /// shows the whole report, which is what the overview panes need.
    private func renderDetail() {
        let sel = store.selection ?? .hardware
        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        switch store.state(for: sel.dataType) {
        case .idle, .loading:
            text.append(NSAttributedString(string: "Gathering information…", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        case .empty:
            text.append(NSAttributedString(string: "No information found.",
                                           attributes: [.font: body, .foregroundColor: NSColor.labelColor]))
        case .loaded(let nodes):
            var shown = nodes
            if !tableScroll.isHidden, tableOutline.selectedRow >= 0,
               let row = tableOutline.item(atRow: tableOutline.selectedRow) as? SPNode {
                shown = [row]
            }
            if shown.isEmpty {
                text.append(NSAttributedString(string: "No information found.",
                                               attributes: [.font: body, .foregroundColor: NSColor.labelColor]))
            }
            for (i, n) in shown.enumerated() { if i > 0 { text.append(NSAttributedString(string: "\n")) }; append(n, depth: 0, into: text, body: body, bold: bold) }
        }
        textView.textStorage?.setAttributedString(text)
        textView.sizeToFit()
    }

    /// Apple lays each section out as "Label:<tab>Value" with one tab stop placed just past
    /// the section's longest label. Sections nest by a 12pt indent.
    private func append(_ node: SPNode, depth: Int, into text: NSMutableAttributedString, body: NSFont, bold: NSFont) {
        let indent = CGFloat(depth) * 12 + 6
        if node.isSection {
            let p = NSMutableParagraphStyle(); p.firstLineHeadIndent = indent; p.headIndent = indent; p.paragraphSpacingBefore = depth == 0 ? 0 : 6
            text.append(NSAttributedString(string: node.label + ":\n" + (depth == 0 ? "\n" : ""), attributes: [.font: bold, .paragraphStyle: p, .foregroundColor: NSColor.labelColor]))
            let leaves = node.children.filter { $0.kind == .pair }
            let widest = leaves.map { ($0.label + ":").size(withAttributes: [.font: body]).width }.max() ?? 0
            let tab = indent + 4 + widest + 8
            for child in node.children {
                if child.isSection { append(child, depth: depth + 1, into: text, body: body, bold: bold); continue }
                if child.kind == .text {
                    let tp = NSMutableParagraphStyle(); tp.firstLineHeadIndent = indent + 4; tp.headIndent = indent + 4
                    text.append(NSAttributedString(string: child.label + "\n", attributes: [.font: body, .paragraphStyle: tp, .foregroundColor: NSColor.labelColor]))
                    continue
                }
                let lp = NSMutableParagraphStyle()
                lp.firstLineHeadIndent = indent + 4; lp.headIndent = tab
                lp.tabStops = [NSTextTab(textAlignment: .left, location: tab, options: [:])]
                lp.defaultTabInterval = 400
                text.append(NSAttributedString(string: "\(child.label):\t\(child.value ?? "")\n", attributes: [.font: body, .paragraphStyle: lp, .foregroundColor: NSColor.labelColor]))
            }
        } else {
            let p = NSMutableParagraphStyle(); p.firstLineHeadIndent = indent; p.headIndent = indent
            let line = node.kind == .pair ? "\(node.label): \(node.value ?? "")" : node.label
            text.append(NSAttributedString(string: line + "\n", attributes: [.font: body, .paragraphStyle: p, .foregroundColor: NSColor.labelColor]))
        }
    }
}

