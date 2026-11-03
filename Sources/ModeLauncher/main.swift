import AppKit
import Foundation
let action = Bundle.main.object(forInfoDictionaryKey: "MacModesAction") as? String ?? "normal"
let address = action == "ocr" ? "macmodes://ocr" : "macmodes://\(action == "normal" ? "set" : "toggle")/\(action)"
if let url = URL(string: address) { NSWorkspace.shared.open(url) }
