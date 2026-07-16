import Foundation
import SwiftUI

let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--headless") {
    Headless.main(Array(arguments[(flagIndex + 1)...]))
} else {
    CopyWatchApp.main()
}
