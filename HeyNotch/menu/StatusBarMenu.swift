import Cocoa

class HeyStatusMenu: NSMenu {
    
    var statusItem: NSStatusItem!
    
    override init() {
        super.init()
        
        // Initialize the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(named: "HeyNotchMenuBar")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("HeyNotch")
            button.action = #selector(showMenu)
        }
        
        // Set up the menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))
        statusItem.menu = menu
    }

}
