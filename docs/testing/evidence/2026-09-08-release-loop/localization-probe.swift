import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bundle = Bundle(url: root),
      let frenchURL = bundle.url(forResource: "fr", withExtension: "lproj"),
      let french = Bundle(url: frenchURL) else {
    throw CocoaError(.fileReadNoSuchFile)
}
let implicit = String(localized: "Dashboard", bundle: bundle, locale: Locale(identifier: "fr"))
let explicit = String(localized: "Dashboard", bundle: french, locale: Locale(identifier: "fr"))
print("implicit=\(implicit); explicit=\(explicit)")
precondition(implicit == "Dashboard")
precondition(explicit == "Tableau de bord")
